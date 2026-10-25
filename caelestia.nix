# =============================================================================
#  Caelestia — shell + vendored dots
# -----------------------------------------------------------------------------
#  The shell has first-class NixOS support (flake only, not in nixpkgs); the
#  dots do NOT, so their Hyprland Lua config is vendored under ./caelestia/hypr
#  (upstream caelestia-dots/caelestia @ c034621845453260b245692b13ce514e7371d735)
#  and installed into ~/.config. Update = re-copy that directory.
#
#  Caelestia owns the bar, background, launcher, lock, idle and notifications,
#  so the old waybar/swaybg/theme-switch units from hyprland.nix are disabled.
# =============================================================================
{ pkgs, lib, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;

  # Pinned to caelestia-dots/shell 4b1dae8 (2026-10-25). The flake brings its
  # own quickshell/cli/m3shapes inputs, so it builds independently of ours.
  caelestia =
    builtins.getFlake "github:caelestia-dots/shell/4b1dae84b1b3b28bf486776ba30c1c1ec74fb64d";

  # NixOS replacement for the Arch-only path the dots' execs.lua hardcodes.
  polkitAgent = pkgs.writeShellScriptBin "polkit-gnome-authentication-agent-1" ''
    exec ${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1
  '';

  hyprVars = pkgs.writeText "caelestia-hypr-vars.lua" (builtins.readFile ./caelestia/hypr-vars.lua);
in
{
  environment.systemPackages = with pkgs; [
    caelestia.packages.${system}.with-cli
    caelestia.inputs.caelestia-cli.packages.${system}.default
    polkitAgent

    # what the dots' execs/keybinds/launcher call
    foot
    cliphist
    trash-cli
    hyprpicker
    swappy
    thunar
    xdg-user-dirs
    bluez
    glib
    jq
    bat
    wl-clipboard
    grim
    slurp
    playerctl
    brightnessctl
    pavucontrol
    networkmanagerapplet

    # fonts the shell asks for
    material-symbols
    rubik
    nerd-fonts.caskaydia-cove
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  # Vendored dots + our app overrides.
  environment.etc = {
    "xdg/caelestia/hypr".source         = ./caelestia/hypr;
    "xdg/caelestia/hypr-vars.lua".source = hyprVars;
  };

  systemd.tmpfiles.rules = [
    # ~/.config/hypr must stay writable: the dots write scheme/current.lua and
    # create ~/.config/caelestia/hypr-user.lua at startup.
    "d /home/k/.config/hypr 0755 k users -"
    "d /home/k/.config/hypr/scheme 0755 k users -"
    "d /home/k/.config/caelestia 0755 k users -"
    "L+ /home/k/.config/hypr/hyprland.lua       - - - - /etc/xdg/caelestia/hypr/hyprland.lua"
    "L+ /home/k/.config/hypr/variables.lua      - - - - /etc/xdg/caelestia/hypr/variables.lua"
    "L+ /home/k/.config/hypr/hyprland           - - - - /etc/xdg/caelestia/hypr/hyprland"
    "L+ /home/k/.config/hypr/utils              - - - - /etc/xdg/caelestia/hypr/utils"
    "L+ /home/k/.config/hypr/scheme/default.lua - - - - /etc/xdg/caelestia/hypr/scheme/default.lua"
    "L+ /home/k/.config/caelestia/hypr-vars.lua - - - - /etc/xdg/caelestia/hypr-vars.lua"
  ];

  # Caelestia replaces the old session bar/background/theme-switcher.
  systemd.user.services.waybar.wantedBy = lib.mkForce [ ];
  systemd.user.services.swaybg.wantedBy = lib.mkForce [ ];
  systemd.user.services.theme-apply.wantedBy = lib.mkForce [ ];
}
