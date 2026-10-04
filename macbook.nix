# =============================================================================
#  Apple MacBook Pro 2016/2017 (T1 iBridge) support
# -----------------------------------------------------------------------------
#  Pulled into `imports` by configuration.nix only on Apple hardware (see the
#  `isMacBook` gate there), so none of this is evaluated or built on the ASUS
#  TUF A15.
#
#  Verified against Linux 7.2.8 / NixOS 26.05: the out-of-tree Touch Bar driver
#  builds cleanly and the Wi-Fi NVRAM derivation is fixed-output.
#
#  What this fixes on a MacBookPro13,2 (2016 13" Touch Bar):
#    * Wi-Fi  - the BCM43602 comes up 2.4 GHz-only and "deaf" without its NVRAM
#               board config. Installing the NVRAM restores 5 GHz plus the
#               TX-power / RF-calibration tables (~26 dB stronger signal).
#    * Touch Bar - Esc + F1-F12 via the out-of-tree T1 iBridge driver.
#    * Keyboard at the LUKS prompt (SPI keyboard modules in initrd).
#    * Suspend/resume (NVMe d3cold) and USB-C after resume (pcie_ports=compat).
#
#  Not handled here: internal audio. The Cirrus CS8409 needs the out-of-tree
#  patchset https://github.com/davidjo/snd_hda_macbookpro; see the notes at the
#  bottom of this file if you want to add it.
# =============================================================================
{ config, pkgs, lib, ... }:

let
  kernel = config.boot.kernelPackages.kernel;

  # -- Wi-Fi NVRAM -----------------------------------------------------------
  # brcmfmac looks for brcm/brcmfmac43602-pcie.txt and, if found, loads it as
  # the chip's board configuration. The stock firmware ships without it, which
  # is why the card reports the placeholder MAC 00:90:4c:xx:xx:xx, only sees
  # 2.4 GHz, and has poor range. This file is a dump from real Apple BCM43602
  # hardware (see nohzafk/omarchy-macbookpro-t1, sourced from MikeRatcliffe).
  #
  # Set this to your MacBook's real Wi-Fi MAC (macOS:  System Information ->
  # Wi-Fi -> Address). If left empty the `macaddr=` line is dropped and
  # brcmfmac uses its own default; the 5 GHz / signal fix still applies.
  macbookWifiMac = "";

  # Pinned source for both the NVRAM blob and the Touch Bar driver.
  omarchyT1 = pkgs.fetchFromGitHub {
    owner = "nohzafk";
    repo = "omarchy-macbookpro-t1";
    rev = "8e479f0af82d16f47de811bef6e1a5cfd7d8c5f8";
    hash = "sha256-cEgysnkoZ2UELA1pBKMePbqeQkVv70f5OrNnk2YyUyk=";
  };

  brcmNvram = pkgs.runCommand "brcmfmac43602-nvram" { } ''
    install -Dm644 ${omarchyT1}/firmware/brcmfmac43602-pcie.txt \
      $out/lib/firmware/brcm/brcmfmac43602-pcie.txt
    ${lib.optionalString (macbookWifiMac == "") ''
      ${pkgs.gnused}/bin/sed -i '/^macaddr=/d' \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.txt
    ''}
    ${lib.optionalString (macbookWifiMac != "") ''
      ${pkgs.gnused}/bin/sed -i \
        's|^macaddr=.*|macaddr=${macbookWifiMac}|' \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.txt
    ''}
  '';

  # -- T1 Touch Bar driver ---------------------------------------------------
  # Out-of-tree HID driver for the iBridge (apple-ibridge + apple-ib-tb +
  # apple-ib-als). The copy in omarchyT1 carries two fixes over the original
  # F13-Kr1pt0n lineage: a struct-ordering build fix, and a re-entrancy guard
  # around the USB config switch that otherwise self-deadlocks and hangs boot.
  # Built against the exact kernel this system boots.
  appleibridge = kernel.stdenv.mkDerivation {
    pname = "appleibridge";
    version = "0.1-unstable-2025-09-02";
    src = "${omarchyT1}/drivers/appleibridge";

    hardeningDisable = [ "pic" ];
    nativeBuildInputs = kernel.moduleBuildDependencies;

    makeFlags = [
      "KERNELRELEASE=${kernel.modDirVersion}"
      "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/modules/${kernel.modDirVersion}/updates"
      cp apple-ibridge.ko apple-ib-tb.ko apple-ib-als.ko \
         "$out/lib/modules/${kernel.modDirVersion}/updates/"
      runHook postInstall
    '';

    meta = {
      description = "T1 iBridge Touch Bar / ambient-light driver for Apple MacBook Pro (2016/2017)";
      homepage = "https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver";
      license = lib.licenses.gpl2Only;
      platforms = [ "x86_64-linux" ];
    };
  };

  # -- Touch Bar enable script ----------------------------------------------
  # Runs late (after multi-user.target), deliberately: if a module wedges, the
  # only cost is a dark Touch Bar, not a hung sysinit.target. It insmods the
  # modules straight from the Nix store (ignoring the modprobe blacklist set
  # below, which keeps udev from autoloading them earlier).
  touchbarEnable = pkgs.writeShellScript "apple-touchbar-enable" ''
    set -u
    export PATH="${lib.makeBinPath (with pkgs; [ kmod coreutils gnugrep ])}:$PATH"

    log() { printf '%s apple-touchbar: %s\n' "$(date '+%H:%M:%S')" "$*"; }

    mods="${appleibridge}/lib/modules/${kernel.modDirVersion}/updates"

    # Nothing to do if the iBridge isn't present. 05ac:1281 means the T1 is in
    # recovery mode (its ESP firmware was wiped) and no driver can help.
    ib=""
    for d in /sys/bus/usb/devices/*/; do
      [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
      case "$(cat "$d/idProduct" 2>/dev/null)" in
        8600) ib=ok ;;
        1281) log "T1 in recovery mode (05ac:1281); ESP firmware missing"; exit 0 ;;
      esac
    done
    [ -n "$ib" ] || { log "no iBridge present"; exit 0; }

    # Coordinator first, in "keyboard" mode: that picks the USB configuration
    # the device already boots in, so the driver never calls
    # usb_set_configuration() and cannot self-deadlock.
    if ! grep -q '^apple_ibridge ' /proc/modules; then
      insmod "$mods/apple-ibridge.ko" tb_mode_param=keyboard \
        || { log "apple-ibridge load failed"; exit 0; }
      log "apple-ibridge loaded"
    fi

    if ! grep -q '^apple_ib_tb ' /proc/modules; then
      insmod "$mods/apple-ib-tb.ko" fnmode=0 idle_timeout=-1 dim_timeout=-1 \
        || log "apple-ib-tb load failed"
    fi

    # hid-sensor-hub grabs the second iBridge HID interface (.0002), which
    # carries the Touch Bar reports. Hand it over to apple-ibridge.
    for d in /sys/bus/hid/devices/*05AC*8600*; do
      [ -e "$d" ] || continue
      dev="$(basename "$d")"
      cur="$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo none)"
      [ "$cur" = "apple-ibridge-hid" ] && continue
      if [ -e "/sys/bus/hid/drivers/$cur/unbind" ]; then
        printf '%s' "$dev" > "/sys/bus/hid/drivers/$cur/unbind" 2>/dev/null && sleep 1
      fi
      if [ -e "/sys/bus/hid/drivers/apple-ibridge-hid/bind" ]; then
        printf '%s' "$dev" > "/sys/bus/hid/drivers/apple-ibridge-hid/bind" 2>/dev/null && sleep 2
      fi
    done

    # apple_ib_tb's probe already ran and found nothing; reload it so it probes
    # again now that .0002 belongs to apple-ibridge.
    tbdir="$(readlink -f /sys/bus/hid/devices/0003:05AC:8600.0001 2>/dev/null || true)"
    if [ -z "$tbdir" ] || [ ! -e "$tbdir/fnmode" ]; then
      rmmod apple-ib-tb 2>/dev/null || true
      sleep 1
      insmod "$mods/apple-ib-tb.ko" fnmode=0 idle_timeout=-1 dim_timeout=-1 2>/dev/null || true
      sleep 2
    fi

    # 0 = Esc + F1-F12 always; -1 = never blank/dim.
    for d in /sys/bus/hid/devices/*05AC*8600*; do
      r="$(readlink -f "$d" 2>/dev/null || true)"
      [ -n "$r" ] && [ -e "$r/fnmode" ] || continue
      printf '0' > "$r/fnmode" 2>/dev/null || true
      printf '%s' '-1' > "$r/idle_timeout" 2>/dev/null || true
      printf '%s' '-1' > "$r/dim_timeout" 2>/dev/null || true
      log "SUCCESS: fnmode=$(cat "$r/fnmode" 2>/dev/null) idle=$(cat "$r/idle_timeout" 2>/dev/null) dim=$(cat "$r/dim_timeout" 2>/dev/null)"
    done
    exit 0
  '';
in
{
  # -- Wi-Fi -----------------------------------------------------------------
  # Pulls in linux-firmware (which has brcmfmac43602-pcie.bin) plus our NVRAM.
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ brcmNvram ];

  # brcmfmac's WPA offload breaks the 4-way handshake with modern
  # wpa_supplicant on these chips; disable that feature.
  boot.extraModprobeConfig = "options brcmfmac feature_disable=0x82000";
  boot.kernelModules = [ "brcmfmac" ];

  # -- Keyboard at the LUKS prompt -------------------------------------------
  # The 2016/2017 keyboard is an SPI device; these must be in initrd for the
  # disk-encryption passphrase to be typeable.
  boot.initrd.kernelModules = [ "intel_lpss_pci" "spi_pxa2xx_platform" "applespi" ];

  # -- Touch Bar -------------------------------------------------------------
  boot.extraModulePackages = [ appleibridge ];
  # Keep udev from autoloading these before the service can pass the safe
  # parameters. The service uses insmod, which is unaffected by blacklisting.
  boot.blacklistedKernelModules = [ "apple-ibridge" "apple-ib-tb" "apple-ib-als" ];

  systemd.services.apple-touchbar = {
    description = "Enable the Apple T1 Touch Bar (iBridge)";
    documentation = [ "https://github.com/nohzafk/omarchy-macbookpro-t1" ];
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExistsGlob = "/sys/bus/hid/devices/*05AC*8600*";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = touchbarEnable;
      TimeoutStartSec = 180;
    };
  };

  # -- Suspend / USB-C -------------------------------------------------------
  # The Apple NVMe controller needs d3cold disabled or resume never completes
  # (the file is reset to 1 on every boot, so re-apply it each boot).
  systemd.services.macbook-nvme-d3cold = {
    description = "Disable d3cold on the Apple NVMe controller (suspend fix)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      p=/sys/bus/pci/devices/0000:01:00.0/d3cold_allowed
      [ -e "$p" ] && echo 0 > "$p" || true
    '';
  };

  # Two Thunderbolt xHCI controllers fail to reset on resume without this,
  # leaving USB-C dead until reboot.
  boot.kernelParams = [ "pcie_ports=compat" ];

  # -- Handy diagnostics -----------------------------------------------------
  environment.systemPackages = with pkgs; [ usbutils pciutils iw ];
}

# -----------------------------------------------------------------------------
#  Optional: internal audio (speakers + mic)
#  The Cirrus CS8409 quirk table only targets Dell subsystems, so Apple's
#  amplifiers stay silent on mainline. davidjo/snd_hda_macbookpro supports
#  kernel 7.x. It is a patched in-tree module, not a plain out-of-tree build,
#  so it is left out to avoid risking the system build. If you want it, the
#  Arch guide in the omarchy README (Part 5) documents the steps.
# -----------------------------------------------------------------------------
