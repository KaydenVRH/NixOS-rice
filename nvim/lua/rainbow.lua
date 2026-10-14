    -- rainbow.lua — oscillating brightness shift
    -- Toggle with :Rainbow or <leader>ur
    
    local started = false
    local tick_handle = nil
    local frame = 0
    
    -- All highlight groups from everforest theme, with their original fg hex
    local groups = {
      Normal       = "#d3c6aa", NormalNC     = "#859289", SignColumn = "#d3c6aa",
      MsgArea      = "#d3c6aa", Cursor       = "#83c092", CursorLine  = nil,
      CursorLineNr = "#83c092", LineNr       = "#859289", FoldColumn   = "#859289",
      Visual       = "#d3c6aa", Search       = "#dbbc7f", IncSearch    = "#e69875",
      Substitute   = "#a7c080", MatchParen   = "#83c092", ColorColumn  = nil,
      Whitespace   = "#343f44", NonText      = "#859289", SpecialKey   = "#859289",
      VertSplit    = "#232a2e", StatusLine   = "#d3c6aa", StatusLineNC = "#859289",
      TabLine      = "#859289", TabLineSel   = "#d3c6aa", TabLineFill  = nil,
      Pmenu        = "#d3c6aa", PmenuSel     = "#83c092", PmenuSbar    = nil,
      PmenuThumb   = "#859289", Question     = "#83c092", ErrorMsg     = "#e67e80",
      WarningMsg   = "#dbbc7f", ModeMsg      = "#83c092", MoreMsg      = "#7fbbb3",
      Title        = "#83c092", Directory    = "#7fbbb3", qfLineNr     = "#83c092",
      qfFileName   = "#83c092", WinSeparator = "#232a2e", EndOfBuffer  = "#2d353b",
      -- Syntax
      Comment      = "#859289", Constant      = "#e69875", String       = "#a7c080",
      Character    = "#a7c080", Number        = "#e69875", Boolean      = "#d699b6",
      Float        = "#e69875", Identifier    = "#d3c6aa", Function     = "#7fbbb3",
      Statement    = "#d699b6", Conditional   = "#d699b6", Repeat       = "#d699b6",
      Label        = "#83c092", Operator      = "#83c092", Keyword      = "#d699b6",
      Exception    = "#e67e80", PreProc       = "#e69875", Include      = "#d699b6",
      Define       = "#d699b6", Macro         = "#e69875", PreCondit    = "#83c092",
      Type         = "#83c092", StorageClass  = "#d699b6", Structure    = "#83c092",
      Typedef      = "#83c092", Special       = "#e69875", SpecialChar  = "#e69875",
      Tag          = "#d699b6", Delimiter     = "#d3c6aa", SpecialComment = "#859289",
      Debug        = "#e67e80", Error         = "#e67e80", Todo         = "#dbbc7f",
      -- Plugin overrides
      NeoTreeDirectoryName = "#83c092", NeoTreeDirectoryIcon = "#83c092",
      NeoTreeRootName      = "#83c092", NeoTreeCursorLine    = "#d3c6aa",
      NeoTreeIndentMarker  = "#859289",
      TelescopeSelection   = "#d3c6aa",
      QuickFixLine         = nil,
    }
    
    -- RGB → HSL helpers
    local function rgb_to_hsl(r, g, b)
      r, g, b = r / 255, g / 255, b / 255
      local mx, mn = math.max(r, g, b), math.min(r, g, b)
      local h, s, l = 0, 0, (mx + mn) / 2
      if mx ~= mn then
        local d = mx - mn
        s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
        if h < 0 then h = h + 360 end
      end
      return h, s, l
    end
    
    local function hsl_to_rgb(h, s, l)
      local c = (1 - math.abs(2 * l - 1)) * s
      local x = c * (1 - math.abs((h / 60) % 2 - 1))
      local m = l - c / 2
      local r1, g1, b1
      if h < 60 then r1, g1, b1 = c, x, 0
      elseif h < 120 then r1, g1, b1 = x, c, 0
      elseif h < 180 then r1, g1, b1 = 0, c, x
      elseif h < 240 then r1, g1, b1 = 0, x, c
      elseif h < 300 then r1, g1, b1 = x, 0, c
      else r1, g1, b1 = c, 0, x end
      return math.floor((r1 + m) * 255 + 0.5),
             math.floor((g1 + m) * 255 + 0.5),
             math.floor((b1 + m) * 255 + 0.5)
    end
    
    local function rotate_hex(hex, deg)
      if not hex then return nil end
      local r = tonumber(hex:sub(2, 3), 16)
      local g = tonumber(hex:sub(4, 5), 16)
      local b = tonumber(hex:sub(6, 7), 16)
      if not r or not g or not b then return hex end
      local h, s, l = rgb_to_hsl(r, g, b)
      if s < 0.01 then s = 0.7 end
      h = (h + deg) % 360
      local r2, g2, b2 = hsl_to_rgb(h, s, l)
      return string.format("#%02x%02x%02x", r2, g2, b2)
    end
    
    local function tick()
      if not started then return end
      frame = frame + 1
      -- oscillate between 0° and 120° (blue ↔ purple/pink)
      local offset = math.sin(frame * 0.025) * 60 + 60
    
      for group, hex in pairs(groups) do
        if hex then
          local new_fg = rotate_hex(hex, offset)
          if new_fg then
            pcall(vim.api.nvim_set_hl, 0, group, { fg = new_fg })
          end
        end
      end
      tick_handle = vim.defer_fn(tick, 100)
    end
    
    local function M_start()
      if started then return end
      started = true
      frame = 0
      tick_handle = vim.defer_fn(tick, 100)
      vim.notify("🌈 rainbow on")
    end
    
    local function M_stop()
      started = false
      tick_handle = nil
      vim.cmd("colorscheme everforest")
      vim.notify("🌈 rainbow off")
    end
    
    local function M_toggle()
      if started then M_stop() else M_start() end
    end
    
    vim.api.nvim_create_user_command("Rainbow", M_toggle, {})
    
    return { start = M_start, stop = M_stop, toggle = M_toggle }
