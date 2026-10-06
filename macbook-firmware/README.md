# Wi-Fi firmware drop-in for the MacBook Pro's BCM43602

Drop Apple's BCM43602 firmware/calibration files here and they are installed
into the system firmware path automatically by `../macbook.nix`. Files are
git-ignored, so you can keep machine-specific blobs locally without committing
them.

## What is needed

| File | Purpose | Where to get it |
|------|---------|-----------------|
| `brcmfmac43602-pcie.txt` | NVRAM board config: antenna map + TX-power tables. **This is the range fix.** | Community copy is bundled automatically; override here if you extract your own. |
| `brcmfmac43602-pcie.clm_blob` | Locale/country matrix (channel power limits) | Apple-only. Generic ones crash the chip. Optional. |
| `brcmfmac43602-pcie.txcap_blob` | TX-capability caps | Apple-only. Optional. |
| `brcmfmac43602-pcie.bin` | Main firmware | Already shipped by `linux-firmware`; only override if you have a newer Apple build. |

If only `brcmfmac43602-pcie.txt` is present (the default), that is the known
high-impact fix and everything still works.

## Extracting the files from macOS (checklist)

Do this on the MacBook itself once macOS is installed again (it must be an
Intel-macOS build that supported the 2016 model, e.g. Monterey/Ventura), or
from a macOS installer image.

1. Boot macOS and open Terminal.
2. The board files historically live in the Wi-Fi kext:
   ```bash
   ls -la /System/Library/Extensions/IO80211Family.kext/Contents/Resources/ \
     | grep -i 43602
   ```
3. Copy whatever `brcmfmac43602*` files exist to this directory:
   ```bash
   cp /System/Library/Extensions/IO80211Family.kext/Contents/Resources/brcmfmac43602* \
      /path/to/macbook-firmware/
   ```
   (Adjust the destination to your NixOS config checkout.)
4. If the `.txt` has a `macaddr=` line, you can leave it; `macbook.nix` will
   strip it unless you set `macbookWifiMac`.
5. If macOS is not installed, search a macOS installer's `InstallESD`/`Payloads`
   (e.g. with Pacifist) for `IO80211Family.kext` and pull the same files out.
6. No `.clm_blob` / `.txcap_blob` found? That is common on newer macOS — the
   `.txt` alone is still worth installing.

## Notes

- Apple Silicon Macs (M-series) use different Broadcom chips (BCM4378/4388) and
  do **not** ship the BCM43602 board files, so a newer Mac cannot donate them.
- The BCM43602 is soldered to the logic board — it cannot be replaced.
