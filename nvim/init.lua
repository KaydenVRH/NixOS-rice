    -- ═══════════════════════════════════════════════════════════════════
    --  Kayden's Neovim Config
    -- ═══════════════════════════════════════════════════════════════════
    
    -- ── 0. Inline Music Player ────────────────────────────────────────
    
    local music = {}
    local mpv_job = nil
    local current_job_id = 0
    music._current_name = nil
    music._playlist = nil
    music._playlist_idx = 0
    music._quitting = false
    music._loop = false
    
    -- Kill mpv on exit to prevent orphans
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        music._quitting = true
        if mpv_job then
          vim.fn.jobstop(mpv_job)
        end
        os.execute("rm -f " .. music._socket .. "; pkill -x mpv 2>/dev/null")
      end,
    })
    
    music._socket = "/tmp/nvim-mpv-socket"
    
    local function mpv_cmd(cmd)
      os.execute("echo '" .. cmd .. "' | nc -U " .. music._socket .. " 2>/dev/null")
    end
    
    function music._spawn(args)
      if music._quitting then return end
      local saved_name = music._current_name
      local saved_playlist = music._playlist
      local saved_idx = music._playlist_idx
      music.stop()
      music._current_name = saved_name
      music._playlist = saved_playlist
      music._playlist_idx = saved_idx
      os.execute("rm -f " .. music._socket)
      table.insert(args, "--input-ipc-server=" .. music._socket)
      current_job_id = current_job_id + 1
      local this_id = current_job_id
      mpv_job = vim.fn.jobstart(args, {
        on_exit = function()
          if current_job_id ~= this_id then return end
          mpv_job = nil
          music._current_name = nil
          music._play_next()
        end,
      })
    end
    
    function music._play_next()
      if music._quitting then return end
      if music._playlist and #music._playlist > 0 then
        music._playlist_idx = music._playlist_idx + 1
        if music._playlist_idx <= #music._playlist then
          music.play(music._playlist[music._playlist_idx])
        elseif music._loop then
          music._playlist_idx = 1
          music.play(music._playlist[1])
        else
          music._playlist = nil
          music._playlist_idx = 0
          vim.notify("♪ playlist finished")
        end
      end
    end
    
    function music._build_playlist(dir, selected_file)
      local files = vim.fn.readdir(dir)
      local playlist = {}
      local exts = { mp3 = true, flac = true, wav = true, ogg = true, m4a = true, aac = true, opus = true, wma = true }
      for _, f in ipairs(files) do
        local ext = vim.fn.fnamemodify(f, ":e"):lower()
        if exts[ext] then
          table.insert(playlist, dir .. "/" .. f)
        end
      end
      table.sort(playlist)
      music._playlist = playlist
      music._playlist_idx = 0
      -- Find selected file in playlist
      if selected_file then
        for i, p in ipairs(playlist) do
          if p == selected_file then
            music._playlist_idx = i
            break
          end
        end
      end
    end
    
    function music.play(path)
      if not path or path == "" then return end
      local name = vim.fn.fnamemodify(path, ":t")
      music._current_name = name
      -- Build playlist from same directory if not already set
      local dir = vim.fn.fnamemodify(path, ":h")
      if not music._playlist or #music._playlist == 0 then
        music._build_playlist(dir, path)
      end
      music._spawn({ "mpv", "--no-terminal", "--no-video", path })
      vim.notify("♪ " .. name)
    end
    
    function music.play_picker()
      -- Use `fd` if available, otherwise `find` for audio extensions
      local find_cmd = vim.fn.executable("fd") == 1
        and { "fd", "--type", "f", "--extension", "mp3", "--extension", "flac",
              "--extension", "wav", "--extension", "ogg", "--extension", "m4a", "--extension", "aac",
              "--extension", "opus", "--extension", "wma" }
        or { "find", ".", "-type", "f", "(",
              "-name", "*.mp3", "-o", "-name", "*.flac", "-o", "-name", "*.wav",
              "-o", "-name", "*.ogg", "-o", "-name", "*.m4a", "-o", "-name", "*.aac",
              "-o", "-name", "*.opus", "-o", "-name", "*.wma", ")" }
    
      require("telescope.builtin").find_files({
        prompt_title = "♪ Music",
        cwd = vim.fn.expand("~/Music"),
        find_command = find_cmd,
        attach_mappings = function(_, map)
          map("i", "<CR>", function(prompt_bufnr)
            local actions = require("telescope.actions")
            local state = require("telescope.actions.state")
            local selection = state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection then
              music.play(selection.path or selection.value)
            end
          end)
          return true
        end,
      })
    end
    
    function music.play_url()
      local url = vim.fn.input("♪ URL: ")
      if url and #url > 0 then
        music._playlist = nil
        music._current_name = url
        music._spawn({ "mpv", "--no-terminal", "--no-video", url })
        vim.notify("♪ playing URL")
      end
    end
    
    function music.toggle()
      mpv_cmd("cycle pause")
      vim.notify("♪ toggled")
    end
    
    function music.stop()
      mpv_cmd("quit")
      if mpv_job then vim.fn.jobstop(mpv_job) end
      mpv_job = nil
      music._current_name = nil
      music._playlist = nil
      music._playlist_idx = 0
    end
    
    function music.next()
      if music._playlist and #music._playlist > 0 then
        music._play_next()
      else
        mpv_cmd("playlist-next")
      end
    end
    
    function music.prev()
      if music._playlist and music._playlist_idx > 1 then
        music._playlist_idx = music._playlist_idx - 1
        music.play(music._playlist[music._playlist_idx])
      else
        mpv_cmd("playlist-prev")
      end
    end
    
    local is_mac = vim.fn.has("macunix") == 1 or vim.fn.has("mac") == 1
    
    function music.volume_up()
      if is_mac then
        os.execute("osascript -e 'set volume output volume (output volume of (get volume settings) + 5)'")
      else
        os.execute("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+ 2>/dev/null")
      end
      vim.notify("♪ +5")
    end
    
    function music.volume_down()
      if is_mac then
        os.execute("osascript -e 'set volume output volume (output volume of (get volume settings) - 5)'")
      else
        os.execute("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- 2>/dev/null")
      end
      vim.notify("♪ -5")
    end
    
    function music.now_playing()
      if music._current_name then
        local total = music._playlist and #music._playlist or 0
        local idx = music._playlist_idx
        local info = "♪ " .. music._current_name
        if total > 0 then info = info .. " [" .. idx .. "/" .. total .. "]" end
        if music._loop then info = info .. " 🔁" end
        vim.notify(info)
      else
        vim.notify("♪ nothing playing")
      end
    end
    
    function music.toggle_loop()
      music._loop = not music._loop
      vim.notify("♪ loop " .. (music._loop and "on 🔁" or "off"))
    end
    
    function music.quit()
      music._quitting = true
      music.stop()
      vim.notify("♪ mpv quit")
    end
    
    -- For lualine
    function music.current()
      return music._current_name and " ♪ " .. music._current_name or ""
    end
    
    
    -- ═══════════════════════════════════════════════════════════════════
    --  1. Lazy.nvim Setup
    -- ═══════════════════════════════════════════════════════════════════
    
    local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
    if not vim.loop.fs_stat(lazypath) then
      vim.fn.system({ "git", "clone", "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
    end
    vim.opt.rtp:prepend(lazypath)
    
    
    -- ═══════════════════════════════════════════════════════════════════
    --  2. Basic Settings
    -- ═══════════════════════════════════════════════════════════════════
    
    vim.g.mapleader = " "
    vim.opt.termguicolors = true
    vim.opt.number = true
    vim.opt.relativenumber = true
    vim.opt.mouse = "a"
    
    -- :q closes buffer, not neovim (like ked)
    vim.cmd([[cnoreabbrev q bdelete]])
    vim.cmd([[cnoreabbrev q! bdelete!]])
    vim.cmd([[cnoreabbrev wq w \| bdelete]])
    vim.keymap.set("n", "<leader>qq", "<cmd>qa<CR>", { silent = true, desc = "Quit all" })
    
    require("rainbow")
    
    
    -- ═══════════════════════════════════════════════════════════════════
    --  3. Plugins
    -- ═══════════════════════════════════════════════════════════════════
    
    require("lazy").setup({
    
      -- ── THEME ─────────────────────────────────────────────────────
      {
        "catppuccin/nvim",
        name = "catppuccin",
        priority = 1000,
        config = function()
          require("catppuccin").setup({
            flavour = "mocha",
            transparent_background = true,
          })
          vim.cmd.colorscheme("catppuccin-mocha")
        end,
      },
    
      -- ── TELESCOPE ─────────────────────────────────────────────────
      {
        "nvim-telescope/telescope.nvim",
        tag = "0.1.8",
        dependencies = { "nvim-lua/plenary.nvim" },
        config = function()
          local ok, _ = pcall(vim.fn.system, { "fd", "--version" })
          local find_cmd = ok and vim.v.shell_error == 0 and {
            "fd", "--type", "f", "--hidden",
            "--exclude", ".git", "--exclude", "Library",
            "--exclude", "node_modules", "--exclude", ".Trash",
            "--exclude", ".cache", "--exclude", ".local/share",
            "--exclude", ".cargo",
          } or nil
    
          require("telescope").setup({
            defaults = {
              file_ignore_patterns = {
                "Library/", ".Trash/", ".local/", ".cache/", ".cargo/",
                "%.pyc", "__pycache__", "node_modules", ".git/",
                "%.o", "%.class", "%.dSYM",
              },
            },
            pickers = {
              find_files = {
                hidden = true,
                find_command = find_cmd,
              },
            },
          })
        end,
      },
    
      -- ── STATUSLINE ────────────────────────────────────────────────
      {
        "nvim-lualine/lualine.nvim",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        config = function()
          local c = {
            bg     = "none",
            fg     = "#cdd6f4",
            dim    = "#6c7086",
            accent = "#cba6f7",
            mid    = "#89b4fa",
          }
          require("lualine").setup({
            options = {
              theme = {
                normal   = { a = { fg = "#1a1a1a", bg = c.accent, gui = "bold" }, b = { fg = c.fg, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
                insert   = { a = { fg = "#1a1a1a", bg = c.mid,   gui = "bold" }, b = { fg = c.fg, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
                visual   = { a = { fg = "#1a1a1a", bg = c.accent, gui = "bold" }, b = { fg = c.fg, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
                replace  = { a = { fg = "#1a1a1a", bg = c.dim,   gui = "bold" }, b = { fg = c.fg, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
                command  = { a = { fg = "#1a1a1a", bg = c.mid,   gui = "bold" }, b = { fg = c.fg, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
                inactive = { a = { fg = c.dim,     bg = c.bg }, b = { fg = c.dim, bg = c.bg }, c = { fg = c.dim, bg = c.bg } },
              },
            },
            sections = {
              lualine_c = { { music.current } },
            },
          })
        end,
      },
    
      -- ── BUFFERLINE ───────────────────────────────────────────────
      {
        "akinsho/bufferline.nvim",
        version = "*",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        config = function()
          require("bufferline").setup({
            options = {
              mode = "buffers",
              numbers = "none",
              indicator = { style = "underline" },
              separator_style = "thin",
              diagnostics = "nvim_lsp",
              themable = false,
              offsets = {
                { filetype = "neo-tree", text = "File Tree", text_align = "center" },
              },
            },
            highlights = {
              fill = { bg = "none" },
              background = { bg = "none" },
              tab = { bg = "none" },
              tab_selected = { bg = "none" },
              separator = { bg = "none" },
              separator_selected = { bg = "none" },
              separator_visible = { bg = "none" },
              close_button = { bg = "none" },
              close_button_selected = { bg = "none" },
              close_button_visible = { bg = "none" },
            },
          })
        end,
      },
    
      -- ── NOICE ────────────────────────────────────────────────────
      {
        "folke/noice.nvim",
        dependencies = { "MunifTanjim/nui.nvim", "rcarriga/nvim-notify" },
        config = function()
          require("noice").setup({
            presets = { bottom_search = true, command_palette = true, long_message_to_split = true },
            messages = { view = "mini" },
          })
        end,
      },
    
      -- ── WHICH‑KEY ────────────────────────────────────────────────
      {
        "folke/which-key.nvim",
        config = function()
          require("which-key").setup({})
        end,
      },
    
      -- ── GITSIGNS ─────────────────────────────────────────────────
      {
        "lewis6991/gitsigns.nvim",
        config = function()
          require("gitsigns").setup({
            signs = {
              add = { text = "│" }, change = { text = "│" }, delete = { text = "_" },
              topdelete = { text = "‾" }, changedelete = { text = "~" },
            },
          })
        end,
      },
    
      -- ── FILE TREE ─────────────────────────────────────────────────
      {
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        dependencies = {
          "nvim-lua/plenary.nvim",
          "nvim-tree/nvim-web-devicons",
          "MunifTanjim/nui.nvim",
        },
        config = function()
          require("neo-tree").setup({
            window = { width = 30 },
            filesystem = { filtered_items = { hide_dotfiles = false } },
          })
        end,
      },
    
      -- ── TERMINAL ──────────────────────────────────────────────────
      {
        "akinsho/toggleterm.nvim",
        version = "*",
        config = function()
          require("toggleterm").setup({
            size = 20,
            open_mapping = [[<c-\>]],
            shade_terminals = false,
            direction = "float",
            float_opts = { border = "curved" },
          })
        end,
      },
    
      -- ── AUTOPAIRS ─────────────────────────────────────────────────
      {
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        config = true,
      },
    
      -- ── LSP (language servers are provided by NixOS; no Mason) ────
      {
        "neovim/nvim-lspconfig",
        dependencies = { "hrsh7th/cmp-nvim-lsp" },
        config = function()
          local capabilities = require("cmp_nvim_lsp").default_capabilities()
          require("lspconfig").lua_ls.setup({
            capabilities = capabilities,
            settings = {
              Lua = {
                runtime = { version = "LuaJIT" },
                diagnostics = { globals = { "vim" } },
                workspace = {
                  library = vim.api.nvim_get_runtime_file("", true),
                  checkThirdParty = false,
                },
                telemetry = { enable = false },
              },
            },
          })
          for _, server in ipairs({ "bashls", "pyright", "gopls" }) do
            require("lspconfig")[server].setup({ capabilities = capabilities })
          end
        end,
      },
    
      -- ── TREESITTER ────────────────────────────────────────────────
      {
        "nvim-treesitter/nvim-treesitter",
        build = ":TSUpdate",
        config = function()
          require("nvim-treesitter").setup({
            ensure_installed = { "lua", "python", "go", "bash", "markdown", "markdown_inline" },
            auto_install = true,
            highlight = { enable = true },
            indent = { enable = true },
          })
        end,
      },
    
      -- ── DASHBOARD ─────────────────────────────────────────────────
      {
        "goolord/alpha-nvim",
        config = function()
          local alpha = require("alpha")
          local theme = require("alpha.themes.dashboard")
    
          theme.section.header.val = {
            "   __             _     ",
            [=[  / /__ ___ _  __(_)_ _ ]=],
            [=[ /  '_// _ \ |/ / /  ' \]=],
            [=[/_/\_\/_//_/___/_/_/_/_/]=],
            "                         ",
            "       k a y d e n       ",
            "                         ",
          }
    
          theme.section.buttons.val = {
            theme.button("f", "    Find file",     "<cmd>Telescope find_files<CR>"),
            theme.button("r", "    Recent files",  "<cmd>Telescope oldfiles<CR>"),
            theme.button("g", "    LazyGit",       "<cmd>LazyGit<CR>"),
            theme.button("e", "    File tree",     "<cmd>Neotree toggle<CR>"),
            theme.button("q", "    Quit",          "<cmd>qa<CR>"),
          }
    
          theme.section.footer.val = {
            "                                                     ",
            "  neovim loaded in " .. os.date("%H:%M:%S"),
          }
    
          theme.section.header.opts.hl = "Constant"
          theme.section.buttons.opts.hl = "String"
    
          alpha.setup(theme.config)
        end,
      },
    
      -- ── LAZYGIT ───────────────────────────────────────────────────
      {
        "kdheepak/lazygit.nvim",
        dependencies = { "nvim-lua/plenary.nvim" },
        keys = {
          { "<leader>lg", "<cmd>LazyGit<CR>", desc = "LazyGit" },
        },
      },
    
      -- ── IMAGE VIEWER ──────────────────────────────────────────────
      {
        "3rd/image.nvim",
        build = "make",
        opts = {
          kitty = { enabled = true, clear_empty_lines = true },
          integrations = {
            markdown = { enabled = true, clear_in_empty_lines = true },
            neorg = { enabled = false },
            nvim_tree = { enabled = true },
          },
        },
      },
    
      -- ── OPENCODE ──────────────────────────────────────────────────
      {
        "nickjvandyke/opencode.nvim",
        version = "*",
        config = function()
          vim.g.opencode_opts = {}
          vim.keymap.set({ "n", "x" }, "<leader>oa",
            function() require("opencode").ask("@this: ", { submit = true }) end,
            { desc = "Ask opencode" })
          vim.keymap.set({ "n", "x" }, "<leader>os",
            function() require("opencode").select() end,
            { desc = "Select opencode" })
          vim.keymap.set("n", "<leader>ot",
            function() require("opencode").toggle() end,
            { desc = "Toggle opencode" })
        end,
      },
    
      -- ── AUTOCOMPLETE ──────────────────────────────────────────────
      {
        "hrsh7th/nvim-cmp",
        dependencies = {
          "hrsh7th/cmp-nvim-lsp",
          "L3MON4D3/LuaSnip",
          "saadparwaiz1/cmp_luasnip",
        },
        config = function()
          local cmp = require("cmp")
          local luasnip = require("luasnip")
    
          cmp.setup({
            snippet = {
              expand = function(args) luasnip.lsp_expand(args.body) end,
            },
            mapping = cmp.mapping.preset.insert({
              ["<C-b>"] = cmp.mapping.scroll_docs(-4),
              ["<C-f>"] = cmp.mapping.scroll_docs(4),
              ["<C-Space>"] = cmp.mapping.complete(),
              ["<C-e>"] = cmp.mapping.abort(),
              ["<CR>"] = cmp.mapping.confirm({ select = true }),
              ["<Tab>"] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_next_item()
                elseif luasnip.expand_or_jumpable() then
                  luasnip.expand_or_jump()
                else
                  fallback()
                end
              end, { "i", "s" }),
              ["<S-Tab>"] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_prev_item()
                elseif luasnip.jumpable(-1) then
                  luasnip.jump(-1)
                else
                  fallback()
                end
              end, { "i", "s" }),
            }),
            sources = cmp.config.sources({
              { name = "nvim_lsp" },
              { name = "luasnip" },
            }, {
              { name = "buffer" },
            }),
          })
        end,
      },
    
    })
    
    
    -- ═══════════════════════════════════════════════════════════════════
    --  4. Transparency
    -- ═══════════════════════════════════════════════════════════════════
    
    local function clear_bg()
      local groups = {
        "Normal", "NormalNC", "SignColumn", "MsgArea",
        "TelescopeNormal", "TelescopeBorder", "TelescopePromptNormal", "TelescopePromptBorder",
        "TelescopeResultsNormal", "TelescopeResultsBorder", "TelescopePreviewNormal", "TelescopePreviewBorder",
        "TelescopeTitle", "TelescopeMultiSelection", "TelescopeMatching", "TelescopeSelectionCaret",
        "TelescopePromptPrefix", "TelescopePromptTitle",
        "NeoTreeNormal", "NeoTreeNormalNC",
        "NoiceCmdlinePopup", "NoiceCmdlinePopupBorder", "NoiceMini",
        "NoiceCmdline", "NoiceInput",
        "ToggleTerm1FloatNormal", "ToggleTerm1FloatBorder",
        "StatusLine", "StatusLineNC", "TabLine", "TabLineFill", "TabLineSel",
        "WinBar", "WinBarNC",
        "LineNr", "LineNrAbove", "LineNrBelow", "CursorLineNr",
      }
      for _, group in ipairs(groups) do
        vim.api.nvim_set_hl(0, group, { bg = "none", ctermbg = "none" })
      end
    end
    
    vim.api.nvim_create_autocmd("ColorScheme", { callback = clear_bg })
    clear_bg()
    -- plugins load after startup; clear again once everything is ready
    vim.api.nvim_create_autocmd("VimEnter", {
      callback = function() vim.schedule(clear_bg) end,
      once = true,
    })
    
    
    -- ═══════════════════════════════════════════════════════════════════
    --  5. Keymaps
    -- ═══════════════════════════════════════════════════════════════════
    
    -- ── General ─────────────────────────────────────────────────────
    local builtin = require("telescope.builtin")
    vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files (cwd)" })
    vim.keymap.set("n", "<leader>fp", function() builtin.find_files({ cwd = vim.fn.expand("~/programs/projects") }) end, { desc = "Find projects" })
    vim.keymap.set("n", "<leader>fd", function() builtin.find_files({ cwd = vim.fn.expand("~/dotfiles") }) end, { desc = "Find dotfiles" })
    vim.keymap.set("n", "<leader>fw", function() builtin.find_files({ cwd = vim.fn.expand("~/Downloads") }) end, { desc = "Find downloads" })
    vim.keymap.set("n", "<leader>fD", function() builtin.find_files({ cwd = vim.fn.expand("~/Documents") }) end, { desc = "Find documents" })
    vim.keymap.set("n", "<leader>e",  ":Neotree toggle<CR>", { silent = true, desc = "File tree" })
    vim.keymap.set("n", "<leader>tt", ":ToggleTerm direction=float<CR>", { silent = true, desc = "Terminal" })
    
    -- ── Buffer switching (like ked's Tab/S-Tab) ────────────────────
    vim.keymap.set("n", "<Tab>",   "<cmd>BufferLineCycleNext<CR>", { silent = true, desc = "Next buffer" })
    vim.keymap.set("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<CR>", { silent = true, desc = "Prev buffer" })
    vim.keymap.set("n", "<leader>bc", "<cmd>bdelete<CR>", { silent = true, desc = "Close buffer" })
    vim.keymap.set("n", "<leader>bp", "<cmd>BufferLinePick<CR>", { silent = true, desc = "Pick buffer" })
    
    -- ── Runner ──────────────────────────────────────────────────────
    vim.keymap.set("n", "<leader>r", function()
      vim.cmd("write")
      local ft = vim.bo.filetype
      local runners = {
        python = "python3 %",
        sh = "bash %",
        lua = "lua %",
        go = "go run %",
      }
      if runners[ft] then
        vim.cmd("TermExec cmd='" .. runners[ft] .. "'")
      else
        vim.notify("No runner for " .. ft, vim.log.levels.WARN)
      end
    end, { desc = "Run file" })
    
    -- ── Paste image ─────────────────────────────────────────────────
    vim.keymap.set("n", "<leader>pi", function()
      local file_dir = vim.fn.expand("%:p:h")
      local assets_dir = file_dir .. "/assets"
      vim.fn.mkdir(assets_dir, "p")
    
      local timestamp = os.date("%Y%m%d_%H%M%S")
      local filename = timestamp .. ".png"
      local filepath = assets_dir .. "/" .. filename
    
      local ok = os.execute("wl-paste --type image > " .. vim.fn.shellescape(filepath) .. " 2>/dev/null")
      if ok ~= 0 then
        vim.notify("No image in clipboard", vim.log.levels.WARN)
        return
      end
    
      local relpath = "assets/" .. filename
      vim.api.nvim_put({ "![](" .. relpath .. ")" }, "c", true, true)
      vim.notify("Pasted " .. relpath)
    end, { desc = "Paste image" })
    
    -- ── Music ───────────────────────────────────────────────────────
    vim.keymap.set("n", "<leader>mp", music.play_picker,  { desc = "Pick music" })
    vim.keymap.set("n", "<leader>mu", music.play_url,     { desc = "Play URL" })
    vim.keymap.set("n", "<leader>mn", music.next,          { desc = "Next track" })
    vim.keymap.set("n", "<leader>mb", music.prev,          { desc = "Prev track" })
    vim.keymap.set("n", "<leader>ms", music.stop,          { desc = "Stop" })
    vim.keymap.set("n", "<leader>mx", music.toggle,        { desc = "Pause/resume" })
    vim.keymap.set("n", "<leader>m=", music.volume_up,     { desc = "Volume up" })
    vim.keymap.set("n", "<leader>m-", music.volume_down,   { desc = "Volume down" })
    vim.keymap.set("n", "<leader>m<space>", music.now_playing, { desc = "Now playing" })
    vim.keymap.set("n", "<leader>mq", music.quit,          { desc = "Quit mpv" })
    vim.keymap.set("n", "<leader>ml", music.toggle_loop,   { desc = "Toggle loop" })
    
    -- ── Rainbow ──────────────────────────────────────────────────────
    vim.keymap.set("n", "<leader>ur", "<cmd>Rainbow<CR>", { desc = "Toggle rainbow hues" })
