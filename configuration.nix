# =============================================================================
#  NixOS — ASUS TUF A15 (2022) — minimal, dark, battery-first
# -----------------------------------------------------------------------------
#  What this is: a small, readable config. asusd/asusctl for the hardware, Ly
#  for login, Hyprland + rofi for the desktop (see hyprland.nix), and an
#  aggressive power setup so the machine lasts away from a socket.
#
#  What this is not: a full desktop environment. There is no bar, no shell, no
#  notification daemon — rofi is the only menu.
# =============================================================================
{ config, pkgs, lib, ... }:

let
  # The machine is an ASUS laptop. asus-nb-wmi only exists on ASUS hardware, so
  # the ASUS services below never activate elsewhere.
  isAsus = builtins.pathExists "/sys/devices/platform/asus-nb-wmi";

  # vesktop (Electron) picks XWayland, which looks blurry under fractional
  # scaling; force native Wayland.
  vesktopWayland = pkgs.symlinkJoin {
    name = "vesktop";
    paths = [ pkgs.vesktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/vesktop --add-flags "--ozone-platform=wayland"
    '';
  };

  # qutebrowser is QtWebEngine; force the native Wayland backend so it is not
  # blurry under the eDP panel's fractional (1.5x) scaling.
  qutebrowserWayland = pkgs.symlinkJoin {
    name = "qutebrowser";
    paths = [ pkgs.qutebrowser ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/qutebrowser --set QT_QPA_PLATFORM wayland
    '';
  };

  # opencode v2 — nixpkgs ships 1.x only. The v2 CLI is a Bun single-file
  # binary that re-execs itself, and patchelf corrupts Bun's payload, so run it
  # unpatched via nix-ld. Bump version + hash together:
  #   nix store prefetch-file https://opencode.ai/files/bin/<version>/opencode-linux-x64.tar.gz
  opencode-v2 = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "opencode";
    version = "2.0.22";
    src = pkgs.fetchurl {
      url = "https://opencode.ai/files/bin/${version}/opencode-linux-x64.tar.gz";
      hash = "sha256-kavIMrNvYZri5MIaM8mIe7yGHpXBSSADq3lw6UhNHvE=";
    };
    nativeBuildInputs = [ pkgs.makeWrapper ];
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 opencode $out/libexec/opencode
      makeWrapper $out/libexec/opencode $out/bin/opencode \
        --set OPENCODE_DISABLE_AUTOUPDATE true
    '';
  };

  # One-click "run Minecraft on the RTX 2050" entry. Same environment as the
  # system `nvidia-offload` script, inlined so this does not depend on it.
  prismlauncher-nvidia = pkgs.writeShellScriptBin "prismlauncher-nvidia" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec ${pkgs.prismlauncher}/bin/prismlauncher "$@"
  '';

  prismlauncher-nvidia-desktop = pkgs.makeDesktopItem {
    name = "prismlauncher-nvidia";
    desktopName = "Prism Launcher (NVIDIA)";
    comment = "Play Minecraft on the RTX 2050 (PRIME offload)";
    exec = "prismlauncher-nvidia %U";
    icon = "org.prismlauncher.PrismLauncher";
    categories = [ "Game" ];
    startupNotify = true;
    extraConfig = { StartupWMClass = "PrismLauncher"; };
  };
in

{
  imports = [
    ./hardware-configuration.nix
    ./hyprland.nix
    ./geforcenow.nix
  ];

  # ===========================================================================
  #  Boot
  # ===========================================================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  # Stable kernel: the NVIDIA driver (595.x) does not build against 7.2 yet,
  # and a laptop has no business tracking -latest anyway.
  boot.kernelPackages = pkgs.linuxPackages;

  # amd_pstate=active lets the EPP interface drive frequency; nmi_watchdog is
  # pure overhead on a laptop.
  #
  # Backlight: on this hybrid AMD+NVIDIA TUF the AMDGPU registers its backlight
  # via eDP AUX, which this panel ignores, and the kernel then hands control to
  # the firmware nvidia_wmi_ec_backlight, which does not drive the panel on a
  # fresh boot either (it only works after a suspend/resume). Force AMDGPU PWM
  # instead; the EC device is blacklisted below so it cannot win the precedence
  # race. Without this the panel comes up near-black before the login screen.
  boot.kernelParams = [
    "amd_pstate=active"
    "nmi_watchdog=0"
    "acpi_backlight=native"
    "amdgpu.backlight=0"
  ];
  boot.blacklistedKernelModules = [ "nvidia_wmi_ec_backlight" ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ===========================================================================
  #  Networking / Bluetooth
  # ===========================================================================
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;
  # Disable IPv6 (fixes Prism Launcher / Microsoft auth).
  networking.enableIPv6 = false;

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # ===========================================================================
  #  Locale / time
  # ===========================================================================
  time.timeZone = "Europe/Amsterdam";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "nl_NL.UTF-8";
    LC_IDENTIFICATION = "nl_NL.UTF-8";
    LC_MEASUREMENT = "nl_NL.UTF-8";
    LC_MONETARY = "nl_NL.UTF-8";
    LC_NAME = "nl_NL.UTF-8";
    LC_NUMERIC = "nl_NL.UTF-8";
    LC_PAPER = "nl_NL.UTF-8";
    LC_TELEPHONE = "nl_NL.UTF-8";
    LC_TIME = "nl_NL.UTF-8";
  };

  # ===========================================================================
  #  Graphics / desktop plumbing
  # ===========================================================================
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;

  programs.nix-ld.enable = true;
  programs.hyprland.enable = true;

  gtk.iconCache.enable = true;
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    GTK_THEME = "adw-gtk3-dark";
    XCURSOR_THEME = "Adwaita";
    XCURSOR_SIZE = "24";
  };

  # LibreWolf is the default for links everywhere; qutebrowser stays one
  # keypress away on SUPER+B (and shows up in rofi).
  xdg.mime.defaultApplications = {
    "text/html" = "librewolf.desktop";
    "x-scheme-handler/http" = "librewolf.desktop";
    "x-scheme-handler/https" = "librewolf.desktop";
    "x-scheme-handler/about" = "librewolf.desktop";
    "x-scheme-handler/unknown" = "librewolf.desktop";
  };

  # Ly, matching the Hyprland palette (#0d0d0f / #8ab4f8).
  services.displayManager.ly = {
    enable = true;
    x11Support = false;
    settings = {
      animation = "colormix";
      colormix_col1 = "0x008ab4f8";
      colormix_col2 = "0x004a6fa5";
      colormix_col3 = "0x000d0d0f";
      animation_frame_delay = 30;
      animation_timeout_sec = 0;
    };
  };
  services.displayManager.defaultSession = "hyprland";

  # ===========================================================================
  #  Audio
  # ===========================================================================
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # Keep Bluetooth headsets on A2DP: removing the HFP/HSP roles stops apps
    # from dropping them to phone-call quality.
    wireplumber.extraConfig."51-bluez-disable-hfp" = {
      "monitor.bluez.properties" = {
        "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
      };
    };
  };

  # ===========================================================================
  #  ASUS hardware
  # ===========================================================================
  services.upower.enable = true;

  services.asusd.enable = lib.mkIf isAsus true;
  programs.rog-control-center.enable = lib.mkIf isAsus true;
  # The shipped unit has no [Install]; wire it up. It also sandboxes with
  # ReadWritePaths=/etc/asusd/, which must exist.
  systemd.services.asusd.wantedBy = lib.mkIf isAsus [ "multi-user.target" ];
  systemd.tmpfiles.rules = lib.mkIf isAsus [
    "d /etc/asusd 0755 root root -"
    # Hyprland 0.55 generates a default ~/.config/hypr/hyprland.lua when it
    # finds none, and that user file then shadows /etc/xdg/hypr/hyprland.lua.
    # Point both it and the kitty config at the Nix-managed ones.
    "d /home/k/.config/hypr 0755 k users -"
    "L+ /home/k/.config/hypr/hyprland.lua - - - - /etc/xdg/hypr/hyprland.lua"
    "L+ /home/k/.config/kitty/kitty.conf - - - - /etc/xdg/kitty/kitty.conf"
    # qutebrowser only reads its config from ~/.config, so link it there.
    "d /home/k/.config/qutebrowser 0755 k users -"
    "L+ /home/k/.config/qutebrowser/config.py - - - - /etc/xdg/qutebrowser/config.py"
  ];

  # The NVIDIA WMI EC backlight comes up very dim on some boots (the EC default
  # is near zero); nudge it to a usable level when that happens.
  systemd.services.backlight-floor = {
    description = "Raise the backlight if it comes up too dim";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      for b in /sys/class/backlight/*/brightness; do
        [ -e "$b" ] || continue
        max=$(cat "$(dirname "$b")/max_brightness" 2>/dev/null) || continue
        cur=$(cat "$b" 2>/dev/null) || continue
        if [ "$cur" -lt $((max / 5)) ]; then
          echo $((max / 2)) > "$b" 2>/dev/null || true
        fi
      done
    '';
  };

  # OpenRGB: udev rules + the i2c modules for the keyboard RGB.
  services.udev.packages = [ pkgs.openrgb ];
  boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];

  # ===========================================================================
  #  Power / battery
  # ---------------------------------------------------------------------------
  #  Two honest profiles rather than one compromise. TLP does the CPU, Wi-Fi,
  #  USB, PCIe and disk power work and flips between them on every AC change:
  #
  #    plugged in -> full performance: governor/EPP "performance", boost on,
  #                  the ASUS "performance" platform profile (higher CPU+GPU
  #                  power limits and an aggressive fan curve), no ASPM or
  #                  device runtime-PM stalls.
  #    on battery -> quiet: powersave/power, boost off, ASUS "quiet" profile,
  #                  deep PCIe ASPM and device runtime PM.
  #
  #  The RTX 2050 stays runtime-suspended (D3) in both cases and wakes only
  #  when an app asks for it with `nvidia-offload`.
  # ===========================================================================
  services.tlp = {
    enable = true;
    settings = {
      # ---- Plugged in: everything as fast as the silicon allows ------------
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_BOOST_ON_AC = 1;

      # This is what actually stops a plugged-in ASUS from throttling.
      PLATFORM_PROFILE_ON_AC = "performance";

      # Keep the buses awake so nothing has to spin up on demand.
      WIFI_PWR_ON_AC = "off";
      RUNTIME_PM_ON_AC = "on";
      AHCI_RUNTIME_PM_ON_AC = "on";
      PCIE_ASPM_ON_AC = "performance";
      SATA_LINKPWR_ON_AC = "max_performance";
      DISK_APM_LEVEL_ON_AC = "254 254";
      SOUND_POWER_SAVE_ON_AC = 0;

      # ---- On battery: save as much as possible -----------------------------
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_BOOST_ON_BAT = 0;

      PLATFORM_PROFILE_ON_BAT = "quiet";

      WIFI_PWR_ON_BAT = "on";
      RUNTIME_PM_ON_BAT = "auto";
      PCIE_ASPM_ON_BAT = "powersupersave";
      SOUND_POWER_SAVE_ON_BAT = 1;

      USB_AUTOSUSPEND = 1;
    };
  };

  # On AC the Radeon 680M is pinned to its highest DPM level for smooth
  # rendering; on battery the driver decides again. The udev rule re-runs this
  # whenever the charger is plugged or unplugged.
  systemd.services.amdgpu-perf = {
    description = "Match the AMD GPU performance level to the power source";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      level=auto
      for p in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
        if [ -e "$p" ] && [ "$(cat "$p")" = 1 ]; then
          level=high
        fi
      done
      for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$f" ] || continue
        echo "$level" > "$f" 2>/dev/null || true
      done
    '';
  };
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", TAG+="systemd", ENV{SYSTEMD_WANTS}+="amdgpu-perf.service"
  '';

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    # Ampere (GA107) supports fine-grained runtime power, so the dGPU can sit
    # in D3 while the iGPU drives the display.
    powerManagement.finegrained = true;
    open = false;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      amdgpuBusId = "PCI:5:0:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  # ===========================================================================
  #  Users
  # ===========================================================================
  users.users."k" = {
    isNormalUser = true;
    description = "k";
    extraGroups = [ "networkmanager" "wheel" "video" ];
  };

  # ===========================================================================
  #  Programs / packages
  # ===========================================================================
  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 10000;
    keyMode = "vi";
    terminal = "screen-256color";
    extraConfig = ''
      set -g mouse on
      set -g status-position top
      set -g status-style 'bg=#1b1b20 fg=#d6d6dd'
      set -g status-left ' #S '
      set -g status-right ' %H:%M '
    '';
  };

  # Secret service so Prism Launcher (and others) can store credentials.
  services.gnome.gnome-keyring.enable = true;

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    # terminal / core utils
    vim
    neovim
    tmux
    git
    gh
    wget
    curl
    unzip
    htop
    btop
    fastfetch
    ripgrep
    fd
    opencode-v2

    # desktop
    adw-gtk3
    papirus-icon-theme
    adwaita-icon-theme

    # browsers
    qutebrowserWayland
    librewolf

    # chat / media
    vesktopWayland
    blueman
    termusic
    yt-dlp

    # gaming
    steam
    prismlauncher
    prismlauncher-nvidia
    prismlauncher-nvidia-desktop

    # asus
    asusctl
    openrgb
  ];

  # ===========================================================================
  #  State
  # ===========================================================================
  system.stateVersion = "26.05";
}
