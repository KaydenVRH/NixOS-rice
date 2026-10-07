# =============================================================================
#  NVIDIA GeForce NOW (cloud game streaming)
# -----------------------------------------------------------------------------
#  GeForce NOW is NOT packaged in nixpkgs: the community `gfn-electron` was
#  removed (alias now throws "abandoned upstream", removed 2025-11-05) and
#  NVIDIA ships its official Linux client only as a Flatpak, hosted on its own
#  remote (not Flathub). We therefore manage it declaratively with nix-flatpak
#  so a `nixos-rebuild switch` installs/updates it automatically.
#
#  * Remote `geforcenow` (NVIDIA) hosts only com.nvidia.geforcenow.
#  * Remote `flathub` supplies the org.freedesktop.Platform//24.08 runtime.
#  * The app is XWayland-only for now: Wayland-native rendering is broken under
#    Hyprland, so we drop the Wayland socket and force x11 (mirrors NVIDIA's
#    own installer).
# =============================================================================
{ ... }:

let
  # Declarative Flatpak manager. Not in nixpkgs; pinned to the v0.7.0 release.
  # Use the pure builtin fetchTree (not pkgs.fetchFromGitHub): the module arg
  # `pkgs` is not available while `imports` is being evaluated, and referencing
  # it there causes infinite recursion. narHash == fetchFromGitHub's hash.
  # Bump rev + narHash together: nix flake prefetch github:gmodena/nix-flatpak/<rev>
  nix-flatpak = builtins.fetchTree {
    type = "github";
    owner = "gmodena";
    repo = "nix-flatpak";
    # v0.7.0 (fetchTree wants the commit sha, not the tag name).
    rev = "440818969ac2cbd77bfe025e884d0aa528991374";
    narHash = "sha256-7ZCulYUD9RmJIDULTRkGLSW1faMpDlPKcbWJLYHoXcs=";
  };
in
{
  imports = [ "${nix-flatpak.outPath}/modules/nixos.nix" ];

  services.flatpak = {
    # The built-in NixOS flatpak module; nix-flatpak layers packages/remotes/
    # overrides on top. xdg.portal is already enabled by programs.hyprland.
    enable = true;

    # Declaring `remotes` replaces nix-flatpak's default (flathub), so list it
    # explicitly alongside NVIDIA's.
    remotes = [
      {
        name = "flathub";
        location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      }
      {
        name = "geforcenow";
        location = "https://international.download.nvidia.com/GFNLinux/flatpak/geforcenow.flatpakrepo";
      }
    ];

    packages = [
      {
        appId = "com.nvidia.geforcenow";
        origin = "geforcenow";
      }
    ];

    # Force XWayland: disable the Wayland socket, hand it the X11 socket, and
    # point SDL at X11. (NIXOS_OZONE_WL is already exported as 1 session-wide.)
    overrides."com.nvidia.geforcenow" = {
      Context.sockets = [ "!wayland" "x11" ];
      Environment = {
        SDL_VIDEODRIVER = "x11";
        NIXOS_OZONE_WL = "0";
      };
    };
  };
}
