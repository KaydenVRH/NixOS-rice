# =============================================================================
#  Apple MacBook Pro 2016/2017 (T1 iBridge) support
# -----------------------------------------------------------------------------
#  Imported by configuration.nix only on Apple hardware (see the `isMacBook`
#  gate there), so nothing here is evaluated or built on the ASUS TUF A15.
#
#  Verified on NixOS 26.05 / Linux 7.2.8: the Touch Bar driver builds cleanly
#  against this kernel and the Wi-Fi firmware derivation is fixed-output.
#
#  What this provides on a MacBookPro13,2 (2016 13" Touch Bar):
#    * Wi-Fi range  - installs the BCM43602 NVRAM board config (the missing
#                     TX-power / antenna calibration that makes the card 2.4GHz
#                     only and "deaf"). Drop Apple's .clm_blob/.txcap_blob into
#                     ../macbook-firmware/ for the fuller fix; see its README.
#    * Touch Bar    - the T1's own firmware draws the strip (Esc, brightness,
#                     media, volume, hold-Fn -> F1-F12) via the freeze-safe
#                     AJ-dev-i60 driver. Webcam keeps working.
#    * Keyboard at the LUKS prompt (SPI keyboard modules in initrd).
#    * Suspend/resume: NVMe d3cold fix and a brcmfmac reload hook.
#
#  Not handled: internal audio (needs davidjo/snd_hda_macbookpro) and the
#  USB-C/Thunderbolt-after-resume power quirk (needs a remove/rescan sleep
#  hook; see the note at the bottom).
# =============================================================================
{ config, pkgs, lib, ... }:

let
  kernel = config.boot.kernelPackages.kernel;

  # -- Touch Bar driver ------------------------------------------------------
  # AJ-dev-i60/t1-touchbar: the roadrunner2 / t2linux lineage ported to kernel
  # 7.x, with a freeze guard. On T1 hardware the ACPI call ASOC.SOCW(1) hard-
  # freezes the machine; this driver skips it by default (DMI-gated) and pins
  # skip_acpi_power=1 below. In USB config 1 the T1 firmware draws the strip, so
  # it survives suspend and the webcam stays usable.
  t1Touchbar = pkgs.fetchFromGitHub {
    owner = "AJ-dev-i60";
    repo = "t1-touchbar";
    rev = "20d65c7b0fe6d05ea9734f869b27384a62de5109";
    hash = "sha256-nDTnPfNCAnx0NzKxt/YBt/QGnZZg8e+Z173uaWiKQUw=";
  };

  appleibDrv = kernel.stdenv.mkDerivation {
    pname = "apple-ib-drv";
    version = "0.1-unstable-2026-07-01";
    src = "${t1Touchbar}/apple-ib-drv";

    hardeningDisable = [ "pic" ];
    nativeBuildInputs = kernel.moduleBuildDependencies;

    makeFlags = [
      "KERNELRELEASE=${kernel.modDirVersion}"
      "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/modules/${kernel.modDirVersion}/updates"
      cp apple-ibridge.ko apple-touchbar.ko \
         "$out/lib/modules/${kernel.modDirVersion}/updates/"
      runHook postInstall
    '';

    meta = {
      description = "T1 iBridge Touch Bar driver for Apple MacBook Pro (2016/2017)";
      homepage = "https://github.com/AJ-dev-i60/t1-touchbar";
      license = lib.licenses.gpl2Only;
      platforms = [ "x86_64-linux" ];
    };
  };

  # -- Wi-Fi firmware --------------------------------------------------------
  # The BCM43602 needs its NVRAM board config (brcmfmac43602-pcie.txt) or it
  # comes up with a placeholder MAC, 2.4GHz only, and almost no range. Apple's
  # clm_blob/txcap_blob improve it further if you can extract them. Files placed
  # in ./macbook-firmware/ override the bundled community NVRAM.
  macbookWifiMac = ""; # set to your real Wi-Fi MAC to pin it (macOS: Wi-Fi -> Address)

  fwDir = ./macbook-firmware;
  hasFw = name: builtins.pathExists (fwDir + "/${name}");

  # Community dump of the Apple NVRAM (same format macOS ships), pinned.
  communityNvram = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/nohzafk/omarchy-macbookpro-t1/8e479f0af82d16f47de811bef6e1a5cfd7d8c5f8/firmware/brcmfmac43602-pcie.txt";
    hash = "sha256-sQnz5mY7DoiMJVnjb34BCfKjprl2V4bRH4SfFtSzLQY=";
  };

  brcmFirmware = pkgs.runCommand "brcmfmac43602-firmware" { } ''
    mkdir -p $out/lib/firmware/brcm

    install -m644 ${
      if hasFw "brcmfmac43602-pcie.txt"
      then fwDir + "/brcmfmac43602-pcie.txt"
      else communityNvram
    } $out/lib/firmware/brcm/brcmfmac43602-pcie.txt

    ${lib.optionalString (hasFw "brcmfmac43602-pcie.clm_blob") ''
      install -m644 ${fwDir}/brcmfmac43602-pcie.clm_blob \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.clm_blob
    ''}
    ${lib.optionalString (hasFw "brcmfmac43602-pcie.txcap_blob") ''
      install -m644 ${fwDir}/brcmfmac43602-pcie.txcap_blob \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.txcap_blob
    ''}
    ${lib.optionalString (hasFw "brcmfmac43602-pcie.bin") ''
      install -m644 ${fwDir}/brcmfmac43602-pcie.bin \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.bin
    ''}

    # The community NVRAM carries a placeholder MAC; drop it unless one was set.
    ${if macbookWifiMac == "" then ''
      ${pkgs.gnused}/bin/sed -i '/^macaddr=/d' \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.txt
    '' else ''
      ${pkgs.gnused}/bin/sed -i \
        's|^macaddr=.*|macaddr=${macbookWifiMac}|' \
        $out/lib/firmware/brcm/brcmfmac43602-pcie.txt
    ''}
  '';
in
{
  # -- Wi-Fi -----------------------------------------------------------------
  # linux-firmware supplies brcmfmac43602-pcie.bin; brcmFirmware adds the NVRAM.
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ brcmFirmware ];

  boot.extraModprobeConfig = ''
    # BCM43602 WPA offload breaks the 4-way handshake with modern wpa_supplicant.
    options brcmfmac feature_disable=0x82000
    # T1 Touch Bar: never run ASOC.SOCW(1) (hard-freezes the machine).
    options apple_ibridge skip_acpi_power=1
  '';

  boot.kernelModules = [ "brcmfmac" "apple-ibridge" ];

  # Reload brcmfmac across suspend/resume: on some resumes the firmware dies
  # while the PCI device still looks alive, so the driver times out forever.
  systemd.services.brcmfmac-reload = {
    description = "Reload brcmfmac across suspend/resume";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'sleep 2; ${pkgs.kmod}/bin/modprobe -r brcmfmac_wcc 2>/dev/null; ${pkgs.kmod}/bin/modprobe -r brcmfmac'";
      ExecStop = "${pkgs.kmod}/bin/modprobe brcmfmac";
    };
  };

  # -- Touch Bar -------------------------------------------------------------
  boot.extraModulePackages = [ appleibDrv ];

  # Keep the iBridge out of USB autosuspend (its suspend path can wedge the T1).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8600", ATTR{power/control}="on"
  '';

  # -- Keyboard at the LUKS prompt -------------------------------------------
  boot.initrd.kernelModules = [ "intel_lpss_pci" "spi_pxa2xx_platform" "applespi" ];

  # -- Suspend: NVMe d3cold --------------------------------------------------
  # The Apple NVMe controller never resumes with d3cold enabled; re-apply each
  # boot because the file resets to 1.
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

  # -- Diagnostics -----------------------------------------------------------
  environment.systemPackages = with pkgs; [ usbutils pciutils iw ];
}

# -----------------------------------------------------------------------------
#  Optional / known gaps
#
#  * USB-C + Thunderbolt after resume: the platform cuts power to the Alpine
#    Ridge controllers in S3, and kernel flags (pcie_ports=compat, etc.) do not
#    help. The working fix is a sleep hook that removes the two Thunderbolt
#    upstream ports before suspend and rescans PCI after resume. See the
#    MacBookPro14,2 ArchWiki section and nohzafk/omarchy-macbookpro-t1.
#
#  * Internal audio: needs the out-of-tree Cirrus CS8409 patchset
#    (davidjo/snd_hda_macbookpro).
# -----------------------------------------------------------------------------
