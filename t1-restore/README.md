# t1-restore — restore the Apple T1 (iBridge) firmware from Linux, no macOS

This is the "Route 2" project: make a MacBookPro13,x / 14,x (2016–2017 Touch Bar)
T1 work again **without installing macOS**, by reimplementing the macOS
`EmbeddedOSInstallService` activation over USB from Linux.

## Why this is needed

The T1 has **no boot ROM**. macOS writes its OS image to the EFI System Partition
at `EFI/APPLE/EMBEDDEDOS/{combined.memboot,FDRData,version.plist}`, and Apple's
boot firmware loads it into the chip on every power-on. Wipe that partition and
the T1 halts in recovery:

```
lsusb | grep 05ac
# 05ac:8600  healthy iBridge  (Touch Bar, camera, Touch ID, ALS all present)
# 05ac:1281  recovery mode    (firmware gone — no driver can fix this)
```

The image is **TSS-personalised per device (ECID)** and cannot be copied from
another Mac. It must be re-derived from Apple's signing servers.

## Status

| Piece | State |
|---|---|
| Apple `EmbeddedOSFirmware.pkg` download + verification | ✅ (URL + SHA-256 in the runbook) |
| Bundle extraction / analysis | ✅ `Watch2,5`, `Customer Boot`, `x619ap`/`x619dev`, build `14Y901` |
| Pinned libimobiledevice toolchain (8 repos) built in Nix | ✅ `nix-build -A t1-restore` |
| libirecovery: T1 device-table entry (`x619ap`/`x619dev`, CPID 0x8002, BDID 0x12/0x13) | ✅ |
| usbmuxd: hotplug device-class filter → `MATCH_ANY` | ✅ |
| idevicerestore: T1 EmbeddedOS activation logic | ❌ **the remaining work** |
| Automation wrapper (Pass A / Pass B / Phase 14 / ESP install) | ❌ (scaffold pending patches) |

The activation logic is not published anywhere (checked GitHub, grep.app). It was
described in a runbook by the original author; we are reconstructing it. It needs
the actual MacBook connected to develop and test — the ASUS alone cannot validate it.

## Firmware bundle facts (from Apple's package)

`Restore.plist`:
- `DeviceClass: Watch`, `ProductType: Watch2,5`, `ProductVersion 3.0`, build `14Y901`
- `DeviceMap`: `BDID 0x12` → `x619ap` (production), `BDID 0x13` → `x619dev`; `CPID 0x8002`
- Restore ramdisk: `048-71112-002.dmg`; OSRamdisk: `048-71103-002.dmg` (both HFS+)

`BuildManifest.plist` — two identities, variant `Customer Boot`, each with:
`DeviceTree, KernelCache, LLB, OSRamdisk, RestoreDeviceTree, RestoreKernelCache,
RestoreRamDisk, RestoreSEP, SEP, ftap, ftsp, iBEC, iBSS, iBoot, rfta, rfts`.

This is a watchOS-style restore, which is why `idevicerestore` is the right base.

## The remaining idevicerestore patches

From the original runbook, gated behind env vars (opt-in, so normal restores are
unaffected). Each is a modification to an existing function:

| Env var | Function(s) | What it must do |
|---|---|---|
| `IDEVICERESTORE_T1_EMBEDDEDOS` | `idevicerestore_start`, `restore.c` options | Restore the bundle with **no host system image / partition restore** (`ShouldRestoreSystemImage=false`, `RootToInstall=false`, no `SystemImage`) |
| `IDEVICERESTORE_RESTORE_BOOT_ARGS` | `restore_send_nor`, `recovery.c` | Use custom `RestoreBootArgs` instead of the built-in default |
| `IDEVICERESTORE_T1_FDR_OUTPUT` | `restore_send_fdr_trust_data`, `fdr.c` | Handle `FDRMemoryCommit` and save the FDR dictionary atomically (mode 0600) |
| `IDEVICERESTORE_T1_FDR_INPUT` | `restore_send_root_ticket` | Add the saved FDR dict to the RootTicket response as `FDRMemoryStoreData` |
| `IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE` / `_TICKET_SAVE` | `get_tss_response`, `personalize_component` | Before phase 11, save the personalised `OSRamdisk+KernelCache+DeviceTree+SEP` as one bare concatenation **and** the matching AP ticket from the same TSS response |
| `IDEVICERESTORE_T1_PHASE14` | restore phase dispatch | Set `auto-boot=false`, send the saved AP ticket, upload the saved image, `boot-args=rd=md0`, blind `memboot` via USB `bRequest=1` |
| `IDEVICERESTORE_OSRAMDISK`, `IDEVICERESTORE_MEMBOOT_OS_IMAGE`, `IDEVICERESTORE_MEMBOOT_FILE`, `IDEVICERESTORE_T1_APTICKET_FILE` | plumbing | File/flag controls used by the above |

Key correctness rules from the runbook:
- The phase-14 image **and** AP ticket must come from the **same** preflight TSS
  transaction as the successful phase-11 restore. A fresh ticket after `FRST`
  produces images that look correctly signed but return the T1 to recovery.
- `combined.memboot` is a bare concatenation `OSRamdisk(osrd) KernelCache(krnl)
  DeviceTree(dtre) SEP(sepi)` — no `2GMI` wrapper.
- Never use a donor `FDRData` / ticket / image from another Mac.

## The workflow the wrapper will automate

```
0.  T1 must be 05ac:1281; back up /boot/efi/EFI/APPLE/EMBEDDEDOS if present
1.  fetch + verify EmbeddedOSFirmware.pkg, extract iBridge1_1Customer.bundle
2.  start a private usbmuxd (patched)
3.  Pass A: restore once, capture device FDRData        (needs gs.apple.com)
4.  wait 10s, FRST the T1, wait for 05ac:1281
5.  Pass B: replay FDRData, capture preflight memboot + AP ticket
6.  wait 10s, FRST again, wait for 05ac:1281
7.  Phase 14: replay the exact image + ticket, blind memboot → 05ac:8600
8.  verify live (lsusb, Touch Bar lights) BEFORE touching the ESP
9.  install the proven combined.memboot + FDRData + version.plist to the ESP atomically
```

## Safety

- **Never evaluate `\_SB.PCI0.XHC1.RHUB.ASOC.SOCW(1)`** — it hard-freezes the T1.
  The only safe reset is `FRST` (`\_SB.PCI0.XHC1.RHUB.ASOC.FRST`, needs `acpi_call`).
- `FDRData`, AP tickets and the personalised image are **ECID-bound** — never
  publish them, never use another machine's.
- Back up the ESP the moment it is restored.

## Build / run

```bash
nix-build /etc/nixos/t1-restore -A t1-restore      # all tools
nix-shell /etc/nixos/t1-restore -A t1-restore      # PATH with the tools
```

To make them available system-wide, add to `configuration.nix`:

```nix
environment.systemPackages = [ (import ./t1-restore { }).t1-restore ];
```

## Next steps

1. Implement the idevicerestore env-var-gated paths above.
2. Write `t1-restore.sh` (the Pass A/B/Phase-14 driver) with `--dry-run` and
   hard guards (refuse to run without a 1281 device; refuse to touch the ESP
   until the live image is proven).
3. Test with the MacBook connected (start with `--dry-run` and `irecovery -q`).
