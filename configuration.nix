# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, pkgs, lib, ... }:

let
  # ASUS TUF A15 support — only on ASUS hardware. The asus-nb-wmi platform
  # device exists on this laptop and is absent on other machines, so the
  # services below never activate on the other laptop.
  isAsusLaptop = builtins.pathExists "/sys/devices/platform/asus-nb-wmi";

  # Apple MacBook Pro support — only on Apple hardware. `applesmc` (the SMC
  # driver) only binds on Macs, so this is false on the TUF A15. Used to pull
  # in ./macbook.nix (Wi-Fi NVRAM + T1 Touch Bar) only where it is relevant.
  isMacBook = builtins.pathExists "/sys/bus/platform/drivers/applesmc"
    || builtins.pathExists "/sys/devices/platform/applesmc.768";

  # vesktop (Electron) picks XWayland, which Hyprland upscales under the 1.5
  # fractional scale, so it looks blurry/pixelated. Force native Wayland.
  vesktopWayland = pkgs.symlinkJoin {
    name = "vesktop";
    paths = [ pkgs.vesktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/vesktop --add-flags "--ozone-platform=wayland"
    '';
  };

  # opencode v2 — nixpkgs only ships 1.x. The v2 CLI is a Bun single-file
  # binary that re-execs itself for its background server, and patchelf
  # corrupts Bun's appended payload, so run it unpatched via nix-ld (enabled
  # below). Bump version + hash to update:
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
in

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./hyprland-rice.nix
    ]
    # Apple MacBook Pro (2016/2017, T1) support: Wi-Fi NVRAM and the Touch Bar
    # driver. Imported only on Apple hardware, so it is inert on the TUF A15.
    ++ lib.optional isMacBook ./macbook.nix;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Keep the boot menu small: only the 10 most recent generations.
  boot.loader.systemd-boot.configurationLimit = 10;

  # Automatic store cleanup so old generations don't pile up.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Disable IPv6 (fixes Prism Launcher / Microsoft auth issues).
  networking.enableIPv6 = false;

  # Bluetooth (BlueZ) - required by bluetui.
  hardware.bluetooth.enable = true;

  # UPower - battery status for the quickshell bar.
  services.upower.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # Select internationalisation properties.
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

  # Enable hardware-accelerated graphics (required for Hyprland).
  hardware.graphics.enable = true;

  # Run prebuilt dynamically-linked binaries (e.g. the opencode v2 CLI)
  # unpatched, via nix-ld. Needed because patchelf corrupts Bun's payload.
  programs.nix-ld.enable = true;

  # ASUS TUF A15: asusd powers the fan/power profiles and the Aura RGB
  # keyboard; rog-control-center is the GUI for them. Gated to ASUS hardware
  # so other laptops are unaffected.
  services.asusd.enable = lib.mkIf isAsusLaptop true;
  programs.rog-control-center.enable = lib.mkIf isAsusLaptop true;
  # The asusd NixOS module only links the unit and the shipped unit has no
  # [Install] section, so asusd never starts. Wire it up ourselves.
  systemd.services.asusd.wantedBy = lib.mkIf isAsusLaptop [ "multi-user.target" ];
  # asusd's unit sandboxes with ReadWritePaths=/etc/asusd/, and fails to start
  # (226/NAMESPACE) if that directory doesn't exist. Create it.
  systemd.tmpfiles.rules = lib.mkIf isAsusLaptop [ "d /etc/asusd 0755 root root -" ];

  # Default keyboard RGB: rainbow cycle, (re)applied whenever asusd is up.
  # asusd also persists this to /etc/asusd/aura_<id>.ron.
  systemd.services.asusd-aura = lib.mkIf isAsusLaptop {
    description = "Set default ASUS keyboard Aura effect (rainbow cycle)";
    after = [ "asusd.service" ];
    requires = [ "asusd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.asusctl}/bin/asusctl aura effect rainbow-cycle --speed med";
    };
  };

  # OpenRGB: udev rules for non-root device access, plus the i2c kernel modules.
  services.udev.packages = [ pkgs.openrgb ];
  boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];

  # Enable Hyprland, a dynamic tiling Wayland compositor.
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # Enable the Ly display manager and default to the Hyprland session.
  services.displayManager.ly = {
    enable = true;
    x11Support = false;

    # Purple color-mixing animation on the login screen.
    settings = {
      animation = "colormix";
      colormix_col1 = "0x00cba6f7"; # light mauve
      colormix_col2 = "0x008b5cf6"; # violet
      colormix_col3 = "0x004c1d95"; # deep purple
      animation_frame_delay = 25;
      animation_timeout_sec = 0;
    };
  };
  services.displayManager.defaultSession = "hyprland";

  # Let Electron/Chromium apps run natively on Wayland.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    # jack.enable = true;

    # Keep Bluetooth headsets (e.g. AirPods) on high-quality A2DP.
    # HFP/HSP (the low-quality "headset" mode) is what kicks in when an app
    # opens the headset mic. Removing those roles leaves only A2DP, so apps
    # like Discord can't drop the headphones to phone-call quality.
    wireplumber.extraConfig."51-bluez-disable-hfp" = {
      "monitor.bluez.properties" = {
        "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
      };
    };
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."k" = {
    isNormalUser = true;
    description = "k";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
    #  thunderbird
    ];
  };

  # tmux with the Catppuccin Mocha theme.
  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 10000;
    keyMode = "vi";
    terminal = "screen-256color";
    plugins = with pkgs.tmuxPlugins; [
      catppuccin
    ];
    extraConfigBeforePlugins = ''
      set -g @catppuccin_flavor 'mocha'
      set -g @catppuccin_window_status_style 'rounded'
      # Must be a real colour (not 'none'): the rounded separators are drawn with
      # the status background, so 'none' makes the half-circles render wrong.
      # Base (#1e1e2e) matches the terminal background.
      set -g @catppuccin_status_background '#1e1e2e'
      set -g @catppuccin_status_connect_separator 'no'
      set -g @catppuccin_status_modules_right 'session date_time'
      set -g @catppuccin_date_time_text '%H:%M'
    '';
    extraConfig = ''
      set -g mouse on
      set -g status-position top
      set -g status-left-length 100
      set -g status-right-length 100
    '';
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Let Firefox hand off prismlauncher:// URLs back to Prism Launcher
  # (used by the Microsoft account login redirect).
  programs.firefox.preferences = {
    "network.protocol-handler.external.prismlauncher" = true;
    "network.protocol-handler.warn-external.prismlauncher" = false;
    "network.protocol-handler.expose.prismlauncher" = true;
  };

  # Secret service so Prism Launcher (and other apps) can store credentials.
  services.gnome.gnome-keyring.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable the modern nix CLI (`nix search`, `nix run`, flakes, ...) without
  # passing --extra-experimental-features every time.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
   environment.systemPackages = with pkgs; [
     vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
     wget
     neovim
     htop
     opencode-v2
     tmux
     bluetui
     prismlauncher
     vesktopWayland
     blueman
     termusic
     steam
     yt-dlp
     openrgb
     gh
     fastfetch
     btop
     cmatrix
   ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}
