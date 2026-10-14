# =============================================================================
#  Neovim — the personal config, restored as real files
# -----------------------------------------------------------------------------
#  The Lua lives under ./nvim/ (init.lua + lua/rainbow.lua) and is installed
#  system-wide to /etc/xdg/nvim, which Neovim reads through XDG_CONFIG_DIRS.
#  lazy.nvim downloads the plugins on first launch; the servers below are the
#  ones the config starts (lua_ls, bashls, pyright, gopls).
# =============================================================================
{ pkgs, ... }:

{
  environment.etc = {
    "xdg/nvim/init.lua".source        = ./nvim/init.lua;
    "xdg/nvim/lua/rainbow.lua".source = ./nvim/lua/rainbow.lua;
  };

  environment.systemPackages = with pkgs; [
    # lazy.nvim, treesitter and the inline music player need these
    lazygit
    mpv
    netcat-openbsd
    tree-sitter
    gcc
    gnumake
    nodejs
    go
    python3

    # LSP servers this config enables
    lua-language-server
    bash-language-server
    pyright
    gopls
  ];
}
