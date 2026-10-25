-- Nix-managed overrides for the vendored Caelestia dots.
-- The dots merge this over hypr/variables.lua; keep it small.
return {
  -- our apps instead of the dots' Arch defaults
  terminal      = "kitty",
  browser       = "librewolf",
  editor        = "kitty -e nvim",
  fileExplorer  = "thunar",
  audioSettings = "pavucontrol",
  cursorTheme   = "Adwaita",
}
