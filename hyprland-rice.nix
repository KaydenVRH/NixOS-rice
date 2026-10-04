# =============================================================================
#  Super-dark Catppuccin Mocha Hyprland rice
# -----------------------------------------------------------------------------
#  ONE self-contained module. Copy this file to another NixOS machine and add
#  it to `imports` in configuration.nix. It installs every package it needs and
#  generates every config file it uses (all of them live here as strings).
#
#  Requires Hyprland (this module enables it) and a Wayland-capable DM (Ly).
# =============================================================================
{ pkgs, lib, ... }:

let
  # -- Theming ---------------------------------------------------------------
  cursorTheme = "catppuccin-mocha-dark-cursors";
  gtkTheme    = "catppuccin-mocha-mauve-standard";
  rounding    = 6; # window + quickshell bar corner radius (kept in sync)

  # Hardware gate: true only on ASUS laptops (this TUF A15). The platform
  # device below is absent on non-ASUS machines, so anything guarded by this
  # flag is inert on other laptops.
  isAsusLaptop = builtins.pathExists "/sys/devices/platform/asus-nb-wmi";

  # Per-device pointer tweak for this laptop's ELAN touchpad (too fast by
  # default). Only emitted on ASUS hardware.
  touchpadLua = lib.optionalString isAsusLaptop ''
    hl.device({
      name          = "elan1203:00-04f3:307a-touchpad",
      sensitivity   = -0.4,
      accel_profile = "flat",
    })
    hl.device({
      name          = "elan1203:00-04f3:307a-mouse",
      sensitivity   = -0.4,
      accel_profile = "flat",
    })
  '';

  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = "mocha";
    accents = [ "mauve" ];
  };

  # QuickMotion: QML motion library providing the shader-based `Genie`
  # (vertex-shader "pour") used for the quickshell popups. Not in nixpkgs.
  quickmotion = pkgs.stdenvNoCC.mkDerivation {
    pname = "quickmotion";
    version = "unstable";
    src = pkgs.fetchFromGitHub {
      owner = "Neftedollar";
      repo = "quickmotion";
      rev = "ecbf4198a07f8bbbed4acfa4eba4bb6786f2b857";
      hash = "sha256-Wf6P8ksVlcW8JhhGiUhQ1JnDl68nSvI3Y/fw/M6rbUQ=";
    };
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/qt-6/qml
      cp -r QuickMotion $out/lib/qt-6/qml/QuickMotion
      runHook postInstall
    '';
  };


  # Auto-detects the CPU temperature sensor (AMD k10temp, Intel coretemp,
  # ARM cpu_thermal, ...) so the bar works on any laptop without edits.
  cpuTemp = pkgs.writeShellScript "waybar-cpu-temp" ''
    for h in /sys/class/hwmon/hwmon*; do
      case "$(cat "$h/name" 2>/dev/null)" in
        k10temp|coretemp|zenpower|cpu_thermal|soc_thermal)
          for f in "$h"/temp*_input; do
            [ -e "$f" ] && exec ${pkgs.gawk}/bin/awk '{ printf "%.0f", $1 / 1000 }' "$f"
          done
          ;;
      esac
    done
    printf "?"
  '';

  # Emits KEY=VALUE statistics for the quickshell bar (temp/cpu/mem/disk/net/brightness).
  statsScript = pkgs.writeShellScript "qs-stats" ''
    temp="--"
    for h in /sys/class/hwmon/hwmon*; do
      case "$(cat "$h/name" 2>/dev/null)" in
        k10temp|coretemp|zenpower|cpu_thermal|soc_thermal)
          for f in "$h"/temp*_input; do
            if [ -e "$f" ]; then
              temp=$(${pkgs.gawk}/bin/awk '{printf "%.0f", $1/1000}' "$f")
              break 2
            fi
          done ;;
      esac
    done

    read -r _ u n s i w irq sirq st _ < /proc/stat
    t1=$((u+n+s+i+w+irq+sirq+st)); i1=$((i+w))
    sleep 0.4
    read -r _ u n s i w irq sirq st _ < /proc/stat
    t2=$((u+n+s+i+w+irq+sirq+st)); i2=$((i+w))
    dt=$((t2-t1)); di=$((i2-i1))
    if [ "$dt" -gt 0 ]; then cpu=$(( 100*(dt-di)/dt )); else cpu=0; fi

    mem=$(${pkgs.gawk}/bin/awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{ if (t>0) printf "%.0f", 100*(t-a)/t; else print 0 }' /proc/meminfo)

    disk=$(df -P / 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{ gsub("%","",$5); print $5 }')
    [ -z "$disk" ] && disk="--"

    net=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | head -1 | cut -d: -f1)
    [ -z "$net" ] && net="offline"

    bright=0
    for b in /sys/class/backlight/*; do
      cur=$(cat "$b/brightness" 2>/dev/null)
      max=$(cat "$b/max_brightness" 2>/dev/null)
      if [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ]; then
        bright=$((100*cur/max))
      fi
      break
    done

    printf "TEMP=%s\nCPU=%s\nMEM=%s\nDISK=%s\nNET=%s\nBRIGHT=%s\n" \
      "$temp" "$cpu" "$mem" "$disk" "$net" "$bright"
  '';

  # Helper for the quickshell music panel: search / stream / download YouTube
  # (and YouTube Music) audio with yt-dlp + mpv, plus a local library.
  musicScript = pkgs.writeShellScriptBin "qs-music" ''
    export PATH="${pkgs.lib.makeBinPath (with pkgs; [ yt-dlp ffmpeg jq netcat-openbsd mpv procps findutils coreutils curl ])}:$PATH"
    SOCK="''${XDG_RUNTIME_DIR:-/tmp}/qs-music-mpv.sock"
    MUSIC_DIR="''${MUSIC_DIR:-$HOME/Music}"
    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/qs-music"

    ensure_mpv() {
      if ! pgrep -f "input-ipc-server=$SOCK" >/dev/null 2>&1; then
        mpv --no-video --idle=yes --force-window=no --input-ipc-server="$SOCK" >/dev/null 2>&1 &
        i=0
        while [ "$i" -lt 30 ] && [ ! -S "$SOCK" ]; do
          sleep 0.1
          i=$((i + 1))
        done
      fi
    }

    mpv_cmd() {
      printf '%s\n' "$1" | nc -U "$SOCK" >/dev/null 2>&1
    }

    prop() {
      printf '{"command":["get_property","%s"],"request_id":%s}\n' "$2" "$1"
    }

    current_path() {
      [ -S "$SOCK" ] || return 0
      printf '%s\n' "$(prop 1 path)" \
          | timeout 1 nc -q 0 -U "$SOCK" 2>/dev/null \
        | jq -r 'select(.request_id==1) | .data // ""' 2>/dev/null
    }

    case "$1" in
      search)
        shift
        yt-dlp --flat-playlist --no-warnings -J "ytsearch15:$*" 2>/dev/null \
          | jq -r '.entries[]? | [.id, .title, (.duration // 0), (.uploader // "unknown")] | @tsv'
        ;;
      play)
        ensure_mpv
        mpv_cmd "$(jq -cn --arg u "https://www.youtube.com/watch?v=$2" '{command:["loadfile",$u,"replace"]}')"
        ;;
      playfile)
        ensure_mpv
        mpv_cmd "$(jq -cn --arg p "$2" '{command:["loadfile",$p,"replace"]}')"
        ;;
      toggle)
        mpv_cmd '{"command":["cycle","pause"]}'
        ;;
      stop)
        mpv_cmd '{"command":["stop"]}'
        ;;
      seek)
        mpv_cmd "$(jq -cn --argjson d "$2" '{command:["seek",$d,"relative"]}')"
        ;;
      seekabs)
        mpv_cmd "$(jq -cn --argjson p "$2" '{command:["seek",$p,"absolute"]}')"
        ;;
      download)
        mkdir -p "$MUSIC_DIR"
        yt-dlp -x --audio-format mp3 --audio-quality 0 --embed-thumbnail --add-metadata \
          -o "$MUSIC_DIR/%(title)s.%(ext)s" "https://www.youtube.com/watch?v=$2" >/dev/null 2>&1
        ;;
      library)
        mkdir -p "$MUSIC_DIR"
        find "$MUSIC_DIR" -type f \
          \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.opus' -o -iname '*.flac' \
             -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.webm' -o -iname '*.aac' \) \
          -printf '%f\t%p\n' 2>/dev/null | sort
        ;;
      now)
        [ -S "$SOCK" ] || exit 0
        printf '%s\n' \
          "$(prop 1 media-title)" \
          "$(prop 2 duration)" \
          "$(prop 3 time-pos)" \
          "$(prop 4 pause)" \
          "$(prop 5 path)" \
          "$(prop 6 metadata)" \
          "$(prop 7 volume)" \
        | timeout 1 nc -q 0 -U "$SOCK" 2>/dev/null \
          | jq -rs '
              def val(id): (map(select(.request_id==id))[0]) as $o
                | if ($o|type)=="object" and ($o|has("data")) then $o.data else "" end;
              [ (val(1)), (val(2)), (val(3)), (val(4)), (val(5)),
                ((val(6)) | if type=="object" then (.artist // .ARTIST // .album_artist // "") else "" end),
                (val(7)) ] | @tsv'
        ;;
      cover)
        src="$2"
        [ -z "$src" ] && src="$(current_path)"
        [ -z "$src" ] && exit 0
        mkdir -p "$CACHE_DIR"
        key=$(printf '%s' "$src" | sha1sum | cut -d' ' -f1)
        out="$CACHE_DIR/cover-$key.jpg"
        if [ ! -s "$out" ]; then
          case "$src" in
            http*|*youtu.be*|*youtube.com*)
              thumb=$(yt-dlp --no-warnings --get-thumbnail "$src" 2>/dev/null | head -1)
              if [ -n "$thumb" ]; then
                curl -fsSL "$thumb" -o "$out" 2>/dev/null || rm -f "$out"
              fi
              ;;
            *)
              if [ -f "$src" ]; then
                ffmpeg -v error -y -i "$src" -map 0:v -frames:v 1 -f image2 "$out" 2>/dev/null || rm -f "$out"
              fi
              ;;
          esac
        fi
        [ -s "$out" ] && printf '%s\n' "$out"
        ;;
    esac
  '';

  # Waits until Hyprland has exported HYPRLAND_INSTANCE_SIGNATURE (and friends)
  # into the systemd user manager, imports that environment, then runs the
  # command. Waybar starts at login before that export happens, which otherwise
  # makes it disable its hyprland/workspaces and hyprland/window modules.
  waitForHyprland = pkgs.writeShellScript "wait-for-hyprland" ''
    i=0
    while [ "$i" -lt 240 ]; do
      if systemctl --user show-environment 2>/dev/null | grep -q '^HYPRLAND_INSTANCE_SIGNATURE='; then
        break
      fi
      i=$((i + 1))
      sleep 0.5
    done
    eval "$(systemctl --user show-environment 2>/dev/null)"
    exec "$@"
  '';

  wallpaperPng =
    "${pkgs.nixos-artwork.wallpapers.catppuccin-mocha}"
    + "/share/wallpapers/catppuccin-mocha/contents/images/nixos-wallpaper-catppuccin-mocha.png";

  # -- Terminal / app choices ------------------------------------------------
  terminal = "kitty";
  fileManager = "nemo";
  menu = "rofi -show drun -config /etc/xdg/rofi/config.rasi";
  browser = "librewolf";

  # ===========================================================================
  #  Hyprland  (0.55+ Lua config, read from /etc/xdg/hypr/hyprland.lua)
  # ===========================================================================
  hyprlandLua = ''
    -- Super-dark Catppuccin Mocha rice -- generated by hyprland-rice.nix

    local terminal    = "${terminal}"
    local fileManager = "${fileManager}"
    local menu        = "${menu}"
    local browser     = "${browser}"
    local mainMod     = "SUPER"

    ----------------------------------------------------------------
    ---- MONITORS --------------------------------------------------
    ----------------------------------------------------------------
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

    ----------------------------------------------------------------
    ---- ENVIRONMENT -----------------------------------------------
    ----------------------------------------------------------------
    hl.env("XCURSOR_THEME",   "${cursorTheme}")
    hl.env("XCURSOR_SIZE",    "24")
    hl.env("HYPRCURSOR_THEME","${cursorTheme}")
    hl.env("HYPRCURSOR_SIZE", "24")
    hl.env("NIXOS_OZONE_WL",  "1")

    ----------------------------------------------------------------
    ---- AUTOSTART -------------------------------------------------
    ----------------------------------------------------------------
    -- Quickshell, swaybg and nm-applet are managed as systemd user services
    -- by this module (see systemd.user.services), because launching them from
    -- Hyprland's startup exec races the Wayland socket at login.

    ----------------------------------------------------------------
    ---- LOOK AND FEEL ---------------------------------------------
    ----------------------------------------------------------------
    hl.config({
      general = {
        gaps_in        = 4,
        gaps_out       = 8,
        border_size    = 1,          -- thin border
        resize_on_border = true,
        allow_tearing  = false,
        layout         = "dwindle",

        col = {
          active_border   = { colors = { "rgba(cba6f7ee)", "rgba(89b4faee)" }, angle = 45 },
          inactive_border = "rgba(313244aa)",
        },
      },

      decoration = {
        rounding       = ${toString rounding},
        rounding_power = 2,
        active_opacity   = 1.0,
        inactive_opacity = 0.97,

        shadow = {
          enabled      = true,
          range        = 4,
          render_power = 3,
          color        = 0xee11111b,
        },

        blur = {
          enabled  = true,
          size     = 6,
          passes   = 2,
          vibrancy = 0.2,
        },
      },

      animations = { enabled = true },

      dwindle = { preserve_split = true },

      misc = {
        force_default_wallpaper = 0,     -- no anime mascot wallpaper
        disable_hyprland_logo   = true,  -- no hyprland logo background
      },

      input = {
        kb_layout      = "us",
        repeat_rate    = 40,     -- keys/second (default 25)
        repeat_delay   = 400,    -- ms before repeat kicks in (default 600)
        follow_mouse   = 1,
        -- force_no_accel makes Hyprland use libinput's *unaccelerated* delta,
        -- which bypasses `sensitivity` entirely. Keep it off so sensitivity
        -- (global + the per-device touchpad override) actually applies.
        sensitivity    = 0,
        accel_profile  = "flat",  -- disable pointer acceleration
        force_no_accel = false,
        touchpad       = { natural_scroll = false },
      },

      -- Software cursors: fixes the cursor flickering/disappearing on
      -- external monitors (a hardware-cursor/scanout issue common on
      -- multi-monitor + mixed-refresh setups).
      cursor = {
        no_hardware_cursors = true,
        use_cpu_buffer      = true,
      },
    })

    -- Per-device (touchpad) pointer speed ---------------------------
${touchpadLua}

    -- Curves -------------------------------------------------------
    hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1} } })
    hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
    hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1} } })
    hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1} } })
    hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1} } })
    hl.curve("overshot",       { type = "bezier", points = { {0.05, 0.9},  {0.1, 1.05} } })
    hl.curve("md3_decel",      { type = "bezier", points = { {0.05, 0.7},  {0.1, 1} } })
    hl.curve("md3_accel",      { type = "bezier", points = { {0.3, 0},     {0.8, 0.15} } })
    hl.curve("menu_decel",     { type = "bezier", points = { {0.1, 1},     {0, 1} } })
    hl.curve("menu_accel",     { type = "bezier", points = { {0.52, 0.03}, {0.72, 0.08} } })

    -- Springs ------------------------------------------------------
    hl.curve("easy",   { type = "spring", mass = 1, stiffness = 71.2633, dampening = 15.8273644 })
    hl.curve("snappy", { type = "spring", mass = 1, stiffness = 120,     dampening = 18 })
    hl.curve("bouncy", { type = "spring", mass = 1, stiffness = 230,     dampening = 14 })

    -- Animations (relaxed pace, still springy) ----------------------
    hl.animation({ leaf = "global",        enabled = true, speed = 9,    bezier = "default" })
    hl.animation({ leaf = "border",        enabled = true, speed = 5.0,  bezier = "md3_decel" })
    hl.animation({ leaf = "windows",       enabled = true, speed = 4.0,  spring = "bouncy" })
    hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.0,  bezier = "overshot",   style = "popin 85%" })
    hl.animation({ leaf = "windowsOut",    enabled = true, speed = 2.2,  bezier = "menu_accel", style = "popin 85%" })
    hl.animation({ leaf = "fadeIn",        enabled = false })
    hl.animation({ leaf = "fadeOut",       enabled = false })
    hl.animation({ leaf = "fade",          enabled = false })
    hl.animation({ leaf = "layers",        enabled = true, speed = 3.5,  bezier = "easeOutQuint" })
    hl.animation({ leaf = "layersIn",      enabled = true, speed = 4.0,  bezier = "menu_decel", style = "slide" })
    hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.8,  bezier = "menu_accel", style = "slide" })
    hl.animation({ leaf = "fadeLayersIn",  enabled = false })
    hl.animation({ leaf = "fadeLayersOut", enabled = false })
    hl.animation({ leaf = "workspaces",    enabled = true, speed = 4.0,  bezier = "overshot",   style = "slide" })
    hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 4.0,  bezier = "overshot",   style = "slide" })
    hl.animation({ leaf = "workspacesOut", enabled = true, speed = 3.0,  bezier = "menu_accel", style = "slide" })
    hl.animation({ leaf = "zoomFactor",    enabled = true, speed = 6,    bezier = "quick" })

    ----------------------------------------------------------------
    ---- KEYBINDINGS -----------------------------------------------
    ----------------------------------------------------------------
    -- Apps ----------------------------------------------------------
    hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
    hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd(fileManager))
    hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd(menu))
    hl.bind(mainMod .. " + B",      hl.dsp.exec_cmd(browser))
    hl.bind(mainMod .. " + L",      hl.dsp.exec_cmd("hyprlock --config /etc/xdg/hypr/hyprlock.conf"))
    hl.bind(mainMod .. " + N",      hl.dsp.exec_cmd("quickshell -c rice ipc call notifications toggle"))
    hl.bind(mainMod .. " + space",  hl.dsp.exec_cmd("quickshell -c rice ipc call launcher toggle"))
    hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exec_cmd("quickshell -c rice ipc call music toggle"))

    -- Window management --------------------------------------------
    hl.bind(mainMod .. " + Q",         hl.dsp.window.close())
    hl.bind(mainMod .. " + C",         hl.dsp.window.close())
    hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.window.kill())
    hl.bind(mainMod .. " + V",         hl.dsp.window.float({ action = "toggle" }))
    hl.bind(mainMod .. " + P",         hl.dsp.window.pseudo())
    hl.bind(mainMod .. " + T",         hl.dsp.layout("togglesplit"))
    hl.bind(mainMod .. " + F",         hl.dsp.window.fullscreen())
    hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "maximized" }))

    -- Scratchpad ----------------------------------------------------
    hl.bind(mainMod .. " + grave",         hl.dsp.workspace.toggle_special("magic"))
    hl.bind(mainMod .. " + SHIFT + grave", hl.dsp.window.move({ workspace = "special:magic" }))

    -- Quit ----------------------------------------------------------
    hl.bind(mainMod .. " + M", hl.dsp.exit())

    -- Focus (arrows or vim h/j/k/l) --------------------------------
    hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
    hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
    hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
    hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))
    hl.bind(mainMod .. " + h",     hl.dsp.focus({ direction = "left" }))
    hl.bind(mainMod .. " + l",     hl.dsp.focus({ direction = "right" }))
    hl.bind(mainMod .. " + k",     hl.dsp.focus({ direction = "up" }))
    hl.bind(mainMod .. " + j",     hl.dsp.focus({ direction = "down" }))

    -- Move window (arrows or vim h/j/k/l) --------------------------
    hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }))
    hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }))
    hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }))
    hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }))
    hl.bind(mainMod .. " + SHIFT + h",     hl.dsp.window.move({ direction = "left" }))
    hl.bind(mainMod .. " + SHIFT + l",     hl.dsp.window.move({ direction = "right" }))
    hl.bind(mainMod .. " + SHIFT + k",     hl.dsp.window.move({ direction = "up" }))
    hl.bind(mainMod .. " + SHIFT + j",     hl.dsp.window.move({ direction = "down" }))

    -- Workspaces ----------------------------------------------------
    for i = 1, 10 do
      local key = i % 10
      hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
      hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
    end

    -- Cycle workspaces ----------------------------------------------
    hl.bind(mainMod .. " + Tab",         hl.dsp.focus({ workspace = "e+1" }))
    hl.bind(mainMod .. " + SHIFT + Tab", hl.dsp.focus({ workspace = "e-1" }))
    hl.bind(mainMod .. " + mouse_down",  hl.dsp.focus({ workspace = "e+1" }))
    hl.bind(mainMod .. " + mouse_up",    hl.dsp.focus({ workspace = "e-1" }))

    -- Drag / resize with mouse --------------------------------------
    hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
    hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

    -- Screenshots ---------------------------------------------------
    hl.bind("PRINT",                   hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | wl-copy"))
    hl.bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | wl-copy"))
    hl.bind(mainMod .. " + PRINT",     hl.dsp.exec_cmd("grim - | wl-copy"))

    -- Media / volume / brightness ----------------------------------
    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
    hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })
    hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
    hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
    hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
    hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

    ----------------------------------------------------------------
    ---- WINDOW RULES ----------------------------------------------
    ----------------------------------------------------------------
    hl.window_rule({
      name  = "suppress-maximize-events",
      match = { class = ".*" },
      suppress_event = "maximize",
    })

    hl.window_rule({
      name  = "fix-xwayland-drags",
      match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
      no_focus = true,
    })

    hl.window_rule({
      name  = "float-pavucontrol",
      match = { class = "pavucontrol" },
      float = true,
    })
  '';

  # ===========================================================================
  #  Waybar
  # ===========================================================================
  waybarConfig = ''
    {
      "layer": "top",
      "position": "top",
      "height": 26,
      "spacing": 4,
      "margin-top": 6,
      "margin-left": 10,
      "margin-right": 10,
      "modules-left": [ "hyprland/workspaces", "hyprland/window" ],
      "modules-center": [ "clock" ],
      "modules-right": [ "custom/cpu_temp", "cpu", "memory", "disk", "network", "pulseaudio", "backlight", "battery", "tray" ],

      "hyprland/workspaces": {
        "format": "{icon}",
        "on-click": "activate",
        "sort-by": "number",
        "persistent-workspaces": { "*": 5 },
        "format-icons": {
          "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
          "urgent": "!",
          "default": "•"
        }
      },
      "hyprland/window": {
        "format": "{}",
        "max-length": 50,
        "separate-outputs": true
      },
      "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%a %d %b %Y}",
        "tooltip-format": "<big>{:%B %Y}</big>\n<tt><small>{calendar}</small></tt>"
      },
      "custom/cpu_temp": {
        "exec": "${cpuTemp}",
        "interval": 5,
        "format": " {text}°C",
        "tooltip": false,
        "states": { "warning": 75, "critical": 90 }
      },
      "cpu": {
        "format": " {usage}%",
        "interval": 5
      },
      "memory": {
        "format": "󰍛 {percentage}%",
        "interval": 5,
        "tooltip-format": "{used:0.1f}G / {total:0.1f}G"
      },
      "disk": {
        "path": "/",
        "interval": 30,
        "format": "󰋊 {percentage_used}%",
        "tooltip-format": "{used} / {total} ({percentage_used}%)"
      },
      "battery": {
        "format": "{icon} {capacity}%",
        "format-icons": [ "", "", "", "", "" ],
        "states": { "warning": 30, "critical": 15 },
        "interval": 30
      },
      "network": {
        "format-wifi": "󰖩 {essid}",
        "format-ethernet": "󰈀 {ifname}",
        "format-disconnected": "󰖪 offline",
        "tooltip-format": "{ifname} via {gwaddr}",
        "on-click": "nm-connection-editor"
      },
      "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰝟 muted",
        "format-icons": { "default": [ "", "", "" ] },
        "on-click": "pavucontrol",
        "on-click-right": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
      },
      "backlight": {
        "format": " {percent}%",
        "on-scroll-up": "brightnessctl set 5%+",
        "on-scroll-down": "brightnessctl set 5%-",
        "smooth-scrolling-threshold": 1
      },
      "tray": {
        "icon-size": 16,
        "spacing": 8
      }
    }
  '';

  waybarStyle = ''
    * {
      font-family: "JetBrainsMono Nerd Font", monospace;
      font-size: 12px;
      border: none;
      border-radius: 0;
      min-height: 0;
    }

    window#waybar {
      background: rgba(17, 17, 27, 0.86);
      color: #cdd6f4;
      border: 1px solid rgba(49, 50, 68, 0.9);
      border-radius: 10px;
    }

    tooltip {
      background: #11111b;
      border: 1px solid #313244;
      border-radius: 8px;
    }
    tooltip label { color: #cdd6f4; }

    #workspaces,
    #window,
    #clock,
    #custom-cpu_temp,
    #cpu,
    #memory,
    #disk,
    #network,
    #pulseaudio,
    #backlight,
    #battery,
    #tray {
      padding: 0 8px;
      margin: 3px 2px;
      border-radius: 7px;
    }

    /* Workspaces ------------------------------------------------- */
    #workspaces {
      padding: 0 3px;
      margin: 3px 2px;
    }
    #workspaces button {
      padding: 0 7px;
      margin: 0 1px;
      color: #6c7086;
      background: transparent;
      border-radius: 7px;
      transition: all 180ms ease;
    }
    #workspaces button.empty {
      color: #45475a;
    }
    #workspaces button.visible {
      color: #bac2de;
    }
    #workspaces button.active {
      color: #11111b;
      background: linear-gradient(135deg, #cba6f7 0%, #89b4fa 100%);
      font-weight: bold;
    }
    #workspaces button.urgent {
      color: #f38ba8;
      background: rgba(243, 139, 168, 0.15);
    }
    #workspaces button:hover {
      background: #313244;
      color: #cdd6f4;
    }

    #window { color: #a6adc8; }

    #clock {
      color: #89b4fa;
      font-weight: bold;
    }

    #custom-cpu_temp            { color: #fab387; }
    #custom-cpu_temp.warning    { color: #f9e2af; }
    #custom-cpu_temp.critical   { color: #f38ba8; }

    #cpu    { color: #f9e2af; }
    #memory { color: #a6e3a1; }
    #disk   { color: #94e2d5; }

    #network { color: #89dceb; }

    #pulseaudio { color: #cba6f7; }
    #pulseaudio.muted { color: #6c7086; }

    #backlight { color: #f9e2af; }

    #battery        { color: #a6e3a1; }
    #battery.warning  { color: #fab387; }
    #battery.critical { color: #f38ba8; }

    #tray { color: #cdd6f4; }
  '';

  # ===========================================================================
  #  SwayNotificationCenter
  # ===========================================================================
  swayncConfig = ''
    {
      "positionX": "right",
      "positionY": "top",
      "layer": "overlay",
      "control-center-layer": "top",
      "control-center-width": 380,
      "control-center-margin-top": 8,
      "control-center-margin-bottom": 8,
      "control-center-margin-right": 8,
      "notification-window-width": 360,
      "notification-icon-size": 48,
      "notification-body-image-height": 100,
      "notification-body-image-width": 200,
      "timeout": 6,
      "timeout-low": 4,
      "timeout-critical": 0,
      "fit-to-screen": false,
      "cssPriority": "application",
      "widgets": [ "title", "dnd", "notifications" ],
      "widget-config": {
        "title": {
          "text": "Notifications",
          "clear-all-button": true,
          "button-text": "Clear All"
        },
        "dnd": {
          "text": "Do Not Disturb"
        }
      }
    }
  '';

  swayncStyle = ''
    * {
      font-family: "JetBrainsMono Nerd Font", sans-serif;
      font-size: 14px;
    }

    .control-center {
      background: #11111b;
      border: 1px solid #313244;
      border-radius: 14px;
      color: #cdd6f4;
    }

    .control-center .notification-row:focus,
    .control-center .notification-row:hover {
      background: #1e1e2e;
    }

    .notification {
      background: #1e1e2e;
      border: 1px solid #313244;
      border-radius: 12px;
      margin: 6px 8px;
      padding: 6px;
    }

    .notification-content { padding: 6px; }
    .close-button {
      background: #f38ba8;
      color: #11111b;
      border-radius: 100%;
      margin: 6px;
      padding: 2px;
    }
    .close-button:hover { background: #eba0ac; }

    .notification-default-action:hover { background: #313244; }

    .summary { color: #cdd6f4; font-weight: bold; }
    .body    { color: #a6adc8; }

    .title {
      color: #cdd6f4;
      font-weight: bold;
      margin: 8px 8px 4px 8px;
      font-size: 16px;
    }

    .widget-title button {
      background: #313244;
      color: #cdd6f4;
      border-radius: 8px;
      padding: 4px 10px;
    }
    .widget-title button:hover { background: #45475a; }

    .widget-dnd {
      margin: 8px;
      color: #cdd6f4;
    }
    .widget-dnd > switch {
      background: #313244;
      border-radius: 10px;
    }
    .widget-dnd > switch:checked { background: #cba6f7; }
  '';

  # ===========================================================================
  #  Hyprlock (screen locker) — Catppuccin Mocha, mauve/blue accent
  # ===========================================================================
  hyprlockConf = ''
    $font = JetBrainsMono Nerd Font

    general {
      hide_cursor = true
    }

    animations {
      enabled = true
      bezier = easeOutQuint, 0.23, 1, 0.32, 1
      bezier = easeInOutCubic, 0.65, 0.05, 0.36, 1
      bezier = linear, 0, 0, 1, 1

      animation = fadeIn, 1, 5, easeOutQuint
      animation = fadeOut, 1, 5, easeOutQuint
      animation = inputFieldDots, 1, 2, linear
      animation = inputFieldColors, 1, 4, easeOutQuint
      animation = inputFieldWidth, 1, 4, easeOutQuint
      animation = inputFieldFade, 1, 4, easeOutQuint
    }

    background {
      monitor =
      path = /etc/xdg/hypr/wallpaper.png
      color = rgba(17, 17, 27, 1.0)
      blur_passes = 3
      blur_size = 7
      noise = 0.02
      contrast = 1.05
      brightness = 0.55
      vibrancy = 0.2
      vibrancy_darkness = 0.2
    }

    # Clock
    label {
      monitor =
      text = $TIME
      color = rgba(205, 214, 244, 1.0)
      font_size = 96
      font_family = $font
      position = 0, 175
      halign = center
      valign = center
      shadow_passes = 2
      shadow_size = 6
      shadow_color = rgba(0, 0, 0, 0.45)
    }

    # Date
    label {
      monitor =
      text = cmd[update:60000] date +"%A, %d %B"
      color = rgba(203, 166, 247, 1.0)
      font_size = 20
      font_family = $font
      position = 0, 105
      halign = center
      valign = center
    }

    # Card behind the password field
    shape {
      monitor =
      size = 380, 78
      color = rgba(24, 24, 37, 0.55)
      rounding = 16
      border_size = 1
      border_color = rgba(69, 71, 90, 0.85)
      position = 0, -92
      halign = center
      valign = center
    }

    # Greeting
    label {
      monitor =
      text = 󰌾  Hello, $USER
      color = rgba(166, 173, 200, 1.0)
      font_size = 15
      font_family = $font
      position = 0, -150
      halign = center
      valign = center
    }

    # Password input
    input-field {
      monitor =
      size = 340, 54
      outline_thickness = 2
      rounding = 14
      dots_size = 0.25
      dots_spacing = 0.35
      dots_center = true
      dots_rounding = -1

      outer_color = rgba(203, 166, 247, 1.0) rgba(137, 180, 250, 1.0) 45deg
      inner_color = rgba(49, 50, 68, 0.92)
      font_color = rgba(205, 214, 244, 1.0)
      check_color = rgba(137, 220, 235, 1.0)
      fail_color = rgba(243, 139, 168, 1.0)
      capslock_color = rgba(249, 226, 175, 1.0)

      fade_on_empty = false
      placeholder_text = Enter password…
      fail_text = Wrong password

      position = 0, -92
      halign = center
      valign = center
    }
  '';

  # ===========================================================================
  #  Rofi (app launcher)
  # ===========================================================================
  rofiConfig = ''
    configuration {
      modi: "drun,run,window";
      show-icons: true;
      icon-theme: "Adwaita";
      font: "JetBrainsMono Nerd Font 12";
      terminal: "${terminal}";
      drun-display-format: "{name}";
      display-drun: "  Apps";
      display-run: "  Run";
      display-window: "  Windows";
      matching: "fuzzy";
    }

    * {
      bg:         #1e1e2e;
      bg-alt:     #181825;
      bg-sel:     #313244;
      fg:         #cdd6f4;
      fg-dim:     #6c7086;
      accent:     #cba6f7;
      red:        #f38ba8;

      background-color: transparent;
      text-color:       @fg;
      border-color:     @accent;
      font:             "JetBrainsMono Nerd Font 12";

      /* Override rofi's built-in (light) theme variables so nothing stays white */
      background:                  @bg;
      foreground:                  @fg;
      lightbg:                     @bg-sel;
      lightfg:                     @bg-sel;
      normal-background:           transparent;
      normal-foreground:           @fg;
      alternate-normal-background: transparent;
      alternate-normal-foreground: @fg;
      active-background:           transparent;
      active-foreground:           @accent;
      alternate-active-background: transparent;
      alternate-active-foreground: @accent;
      urgent-background:           transparent;
      urgent-foreground:           @red;
      alternate-urgent-background: transparent;
      alternate-urgent-foreground: @red;
      selected-normal-background:  @bg-sel;
      selected-normal-foreground:  @accent;
      selected-active-background:  @bg-sel;
      selected-active-foreground:  @accent;
      selected-urgent-background:  @red;
      selected-urgent-foreground:  @bg;
      separatorcolor:              @bg-sel;
      bordercolor:                 @accent;
    }

    window {
      width:            38%;
      padding:          14px;
      border:           2px;
      border-radius:    14px;
      border-color:     @accent;
      background-color: @bg;
    }

    mainbox {
      spacing:          12px;
      background-color: transparent;
      children:         [ inputbar, listview ];
    }

    inputbar {
      spacing:          10px;
      padding:          10px 12px;
      border-radius:    10px;
      background-color: @bg-alt;
      children:         [ prompt, entry ];
    }

    prompt {
      text-color:       @accent;
      background-color: transparent;
    }

    entry {
      text-color:        @fg;
      background-color:  transparent;
      placeholder:       "Search...";
      placeholder-color: @fg-dim;
    }

    textbox {
      background-color: transparent;
      text-color:       @fg;
    }

    listview {
      lines:           8;
      spacing:         6px;
      scrollbar:       false;
      border:          0;
      background-color: transparent;
    }

    element {
      spacing:          10px;
      padding:          8px 10px;
      border-radius:    10px;
      background-color: transparent;
    }

    element-icon {
      size:             22px;
      border:           0;
      background-color: transparent;
    }

    element-text {
      background-color: transparent;
      text-color:       inherit;
    }

    overlay {
      background-color: transparent;
    }

    button {
      padding:          4px 10px;
      border-radius:    8px;
      background-color: transparent;
      text-color:       @fg-dim;
    }

    button selected {
      background-color: @bg-sel;
      text-color:       @accent;
    }

    scrollbar {
      background-color: transparent;
      handle-color:     @bg-sel;
      border-color:     @bg-sel;
    }
  '';

  # ===========================================================================
  #  Kitty (terminal) - Catppuccin Mocha, slightly transparent
  # ===========================================================================
  kittyConf = ''
    font_family      JetBrainsMono Nerd Font
    font_size        11.0
    background_opacity 0.9
    confirm_os_window_close 0

    foreground            #cdd6f4
    background            #1e1e2e
    selection_foreground  #1e1e2e
    selection_background  #f5e0dc
    cursor                #f5e0dc
    cursor_text_color     #1e1e2e
    url_color             #f5e0dc

    active_border_color     #b4befe
    inactive_border_color   #6c7086
    active_tab_background   #cba6f7
    active_tab_foreground   #1e1e2e
    inactive_tab_background #181825
    inactive_tab_foreground #cdd6f4

    color0  #45475a
    color8  #585b70
    color1  #f38ba8
    color9  #f38ba8
    color2  #a6e3a1
    color10 #a6e3a1
    color3  #f9e2af
    color11 #f9e2af
    color4  #89b4fa
    color12 #89b4fa
    color5  #f5c2e7
    color13 #f5c2e7
    color6  #94e2d5
    color14 #94e2d5
    color7  #bac2de
    color15 #a6adc8
  '';

  # ===========================================================================
  #  Quickshell bar (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  # ===========================================================================
  #  Quickshell bar + launcher + system menu + music (QML)
  # ===========================================================================
  quickshellQml = ''
    import QtQuick
    import QtQuick.Layouts
    import QtQuick.Effects
    import Quickshell
    import Quickshell.Io
    import Quickshell.Widgets
    import Quickshell.Hyprland
    import Quickshell.Services.SystemTray
    import Quickshell.Services.Notifications
    import Quickshell.Services.Pipewire
    import Quickshell.Services.UPower
    import QuickMotion
    
    ShellRoot {
        id: root
    
        // ---- Catppuccin Mocha palette ----
        readonly property color base:     "#1e1e2e"
        readonly property color mantle:   "#181825"
        readonly property color crust:    "#11111b"
        readonly property color surface0: "#313244"
        readonly property color surface1: "#45475a"
        readonly property color surface2: "#585b70"
        readonly property color text:     "#cdd6f4"
        readonly property color subtext:  "#a6adc8"
        readonly property color overlay:  "#6c7086"
        readonly property color mauve:    "#cba6f7"
        readonly property color blue:     "#89b4fa"
        readonly property color green:    "#a6e3a1"
        readonly property color yellow:   "#f9e2af"
        readonly property color peach:    "#fab387"
        readonly property color red:      "#f38ba8"
        readonly property color teal:     "#94e2d5"
        readonly property color sky:      "#89dceb"
    
        readonly property int radius: ${toString rounding}
        readonly property int barHeight: 30
        readonly property string font: "JetBrainsMono Nerd Font"
    
        property var stats: ({})
        property bool notifCenterOpen: false
        property var toast: null
        property bool launcherOpen: false
        property bool menuOpen: false
        property string query: ""
    
        readonly property var results: {
            const all = DesktopEntries.applications.values.filter(e => !e.noDisplay);
            const q = query.trim().toLowerCase();
            if (q === "")
                return all.slice(0, 8);
            return all.filter(e => {
                const name = (e.name ?? "").toLowerCase();
                const comment = (e.comment ?? "").toLowerCase();
                let kw = "";
                try { kw = (e.keywords ?? []).join(" ").toLowerCase(); } catch (x) { kw = ""; }
                return name.includes(q) || comment.includes(q) || kw.includes(q);
            }).slice(0, 8);
        }
    
        function wsFor(id) {
            const vals = Hyprland.workspaces.values;
            return vals.find(w => w.id === id);
        }
        function focusedMonitorName() {
            return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        }
        function notifPic(n) {
            if (!n) return "";
            const img = n.image ?? "";
            if (img !== "") return img;
            return n.appIcon ?? "";
        }
    
        // ---- music player ----
        property bool musicOpen: false
        property string musicTab: "search"
        property string musicQuery: ""
        property var musicResults: []
        property var musicLibrary: []
        property string nowPlaying: ""
        property var musicQueue: []
        property int musicIndex: -1
        property int musicSel: -1
        property string nowTitle: ""
        property string nowArtist: ""
        property real nowDuration: 0
        property real nowPos: 0
        property bool nowPaused: true
        property string nowPath: ""
        property real nowVolume: 100
        property string coverSource: ""
        property bool downloading: false
    
        // true while any popup is doing its genie pour (makes the clock glow)
        property bool uiAnimating: false
    
        function runMusicSearch() {
            if (musicQuery.trim() === "") return;
            musicSearchProc.command = [ "qs-music", "search", musicQuery ];
            musicSearchProc.running = false;
            musicSearchProc.running = true;
        }
        function musicPlayAt(index) {
            if (index < 0 || index >= musicQueue.length) return;
            const item = musicQueue[index];
            musicIndex = index;
            nowPlaying = item.title;
            if (item.isLocal) Quickshell.execDetached([ "qs-music", "playfile", item.path ]);
            else Quickshell.execDetached([ "qs-music", "play", item.id ]);
        }
        function musicPlayResult(index) {
            musicQueue = musicResults.map(r => ({ id: r.id, title: r.title, isLocal: false }));
            musicPlayAt(index);
        }
        function musicPlayLibrary(index) {
            musicQueue = musicLibrary.map(r => ({ id: "", title: r.name, path: r.path, isLocal: true }));
            musicPlayAt(index);
        }
        function musicNext() { musicPlayAt(musicIndex + 1); }
        function musicPrev() { musicPlayAt(musicIndex - 1); }
        function reloadLibrary() {
            musicLibProc.running = false;
            musicLibProc.running = true;
        }
        function fmtTime(s) {
            if (!s || s < 0 || isNaN(s)) return "0:00";
            const m = Math.floor(s / 60), sec = Math.floor(s % 60);
            return m + ":" + (sec < 10 ? "0" : "") + sec;
        }
        function musicToggle() { Quickshell.execDetached([ "qs-music", "toggle" ]); }
        function musicSeek(delta) { Quickshell.execDetached([ "qs-music", "seek", String(delta) ]); }
        function musicSeekTo(frac) {
            if (nowDuration <= 0) return;
            Quickshell.execDetached([ "qs-music", "seekabs", String(Math.max(0, Math.min(1, frac)) * nowDuration) ]);
        }
        function musicSelCount() { return musicTab === "library" ? musicLibrary.length : musicResults.length; }
        function musicMoveSel(d) {
            const n = musicSelCount();
            if (n === 0) { musicSel = -1; return; }
            if (musicSel < 0) musicSel = d > 0 ? 0 : n - 1;
            else musicSel = Math.max(0, Math.min(n - 1, musicSel + d));
        }
        function musicPlaySelected() {
            if (musicSel < 0 || musicSel >= musicSelCount()) return;
            if (musicTab === "library") musicPlayLibrary(musicSel);
            else musicPlayResult(musicSel);
        }
        function musicSwitchTab() {
            musicTab = musicTab === "search" ? "library" : "search";
            musicSel = -1;
            if (musicTab === "library") reloadLibrary();
        }
        function musicDownload(id) {
            if (id === "" || downloading) return;
            downloading = true;
            musicDownloadProc.command = [ "qs-music", "download", id ];
            musicDownloadProc.running = false;
            musicDownloadProc.running = true;
        }
        function fetchCover(path) {
            if (path === "") { coverSource = ""; return; }
            musicCoverProc.command = [ "qs-music", "cover", path ];
            musicCoverProc.running = false;
            musicCoverProc.running = true;
        }
        function musicKey(e, transport) {
            switch (e.key) {
            case Qt.Key_Escape:
                if (musicSel >= 0) musicSel = -1;
                else root.musicOpen = false;
                e.accepted = true; break;
            case Qt.Key_Tab:
            case Qt.Key_Backtab:
                musicSwitchTab(); e.accepted = true; break;
            case Qt.Key_Up: musicMoveSel(-1); e.accepted = true; break;
            case Qt.Key_Down: musicMoveSel(1); e.accepted = true; break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                if (musicSel >= 0) musicPlaySelected();
                else if (musicTab === "search") runMusicSearch();
                e.accepted = true; break;
            case Qt.Key_Space:
                if (transport) { musicToggle(); e.accepted = true; }
                break;
            case Qt.Key_Left:
                if (transport) { musicSeek(-5); e.accepted = true; }
                break;
            case Qt.Key_Right:
                if (transport) { musicSeek(5); e.accepted = true; }
                break;
            case Qt.Key_N:
                if (transport) { musicNext(); e.accepted = true; }
                break;
            case Qt.Key_P:
                if (transport) { musicPrev(); e.accepted = true; }
                break;
            }
        }
    
        NotificationServer {
            id: notifServer
            actionsSupported: true
            bodySupported: true
            imageSupported: true
            onNotification: (n) => {
                n.tracked = true;
                root.toast = n;
                toastTimer.restart();
            }
        }
    
        Timer {
            id: toastTimer
            interval: 5000
            onTriggered: root.toast = null
        }
    
        Timer {
            id: uiAnimTimer
            interval: 620
            onTriggered: root.uiAnimating = false
        }
    
        PwObjectTracker {
            objects: Pipewire.defaultAudioSink ? [ Pipewire.defaultAudioSink ] : []
        }
    
        Process {
            id: statsProc
            command: [ "${statsScript}" ]
            stdout: StdioCollector {
                id: statsOut
                onStreamFinished: {
                    const o = {};
                    for (const line of statsOut.text.trim().split("\n")) {
                        const i = line.indexOf("=");
                        if (i > 0) o[line.slice(0, i)] = line.slice(i + 1);
                    }
                    root.stats = o;
                }
            }
        }
        Timer {
            interval: 2000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: { statsProc.running = false; statsProc.running = true; }
        }
    
        Process {
            id: musicSearchProc
            command: [ "qs-music", "search", "" ]
            stdout: StdioCollector {
                id: musicSearchOut
                onStreamFinished: {
                    const rows = musicSearchOut.text.trim().split("\n").filter(l => l.length > 0);
                    root.musicResults = rows.map(l => {
                        const p = l.split("\t");
                        return { id: p[0] || "", title: p[1] || "", duration: p[2] || "0", uploader: p[3] || "" };
                    });
                }
            }
        }
    
        Process {
            id: musicLibProc
            command: [ "qs-music", "library" ]
            stdout: StdioCollector {
                id: musicLibOut
                onStreamFinished: {
                    const rows = musicLibOut.text.trim().split("\n").filter(l => l.length > 0);
                    root.musicLibrary = rows.map(l => {
                        const p = l.split("\t");
                        return { name: p[0] || "", path: p[1] || "" };
                    });
                }
            }
        }
    
        // Keep the library refreshed while it is open, so newly downloaded songs show up.
        Timer {
            interval: 4000
            repeat: true
            running: root.musicOpen && root.musicTab === "library"
            onTriggered: root.reloadLibrary()
        }
    
        // Poll mpv for the live track state so the panel reflects reality.
        Process {
            id: musicNowProc
            command: [ "qs-music", "now" ]
            stdout: StdioCollector {
                id: musicNowOut
                onStreamFinished: {
                    const t = musicNowOut.text.trim();
                    if (t === "") return;
                    const p = t.split("\t");
                    root.nowTitle = p[0] ?? "";
                    root.nowDuration = parseFloat(p[1]) || 0;
                    root.nowPos = parseFloat(p[2]) || 0;
                    root.nowPaused = (p[3] === "true");
                    const np = p[4] ?? "";
                    if (np !== root.nowPath) {
                        root.nowPath = np;
                        root.coverSource = "";
                        if (np !== "") root.fetchCover(np);
                    }
                    root.nowArtist = p[5] ?? "";
                    root.nowVolume = parseFloat(p[6]) || 0;
                }
            }
        }
        Timer {
            interval: 1000
            repeat: true
            running: true
            triggeredOnStart: true
            onTriggered: { if (!musicNowProc.running) musicNowProc.running = true; }
        }
    
        Process {
            id: musicCoverProc
            command: [ "qs-music", "cover", "" ]
            stdout: StdioCollector {
                id: musicCoverOut
                onStreamFinished: root.coverSource = musicCoverOut.text.trim();
            }
        }
    
        Process {
            id: musicDownloadProc
            command: [ "qs-music", "download", "" ]
            onRunningChanged: {
                if (!running) {
                    root.downloading = false;
                    root.reloadLibrary();
                }
            }
        }
    
        IpcHandler {
            target: "notifications"
            function toggle(): void { root.notifCenterOpen = !root.notifCenterOpen; }
            function open(): void { root.notifCenterOpen = true; }
            function close(): void { root.notifCenterOpen = false; }
        }
    
        IpcHandler {
            target: "launcher"
            function toggle(): void { root.launcherOpen = !root.launcherOpen; }
            function open(): void { root.launcherOpen = true; }
            function close(): void { root.launcherOpen = false; }
        }
    
        IpcHandler {
            target: "menu"
            function toggle(): void { root.menuOpen = !root.menuOpen; }
            function open(): void { root.menuOpen = true; }
            function close(): void { root.menuOpen = false; }
        }
    
        IpcHandler {
            target: "music"
            function toggle(): void {
                root.musicOpen = !root.musicOpen;
                if (root.musicOpen && root.musicTab === "library") root.reloadLibrary();
            }
            function open(): void { root.musicOpen = true; }
            function close(): void { root.musicOpen = false; }
        }
    
        Variants {
            model: Quickshell.screens
    
            delegate: Item {
                id: perScreen
                property var modelData
    
                readonly property bool isFocused: root.focusedMonitorName() === (perScreen.modelData ? perScreen.modelData.name : "")
    
                // ============================ BAR ============================
                PanelWindow {
                    screen: perScreen.modelData
                    anchors { top: true; left: true; right: true }
                    margins { top: 6; left: 10; right: 10 }
                    implicitHeight: root.barHeight
                    color: "transparent"
                    exclusiveZone: root.barHeight + 6
    
                    Rectangle {
                        anchors.fill: parent
                        radius: root.radius
                        color: Qt.rgba(0.067, 0.067, 0.102, 0.86)
                        border.width: 1
                        border.color: root.surface0
    
                        // Clock (glows while a popup is pouring out of it)
                        Item {
                            id: clockWrap
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: clockText.width
                            implicitHeight: clockText.height
    
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width + 26
                                height: parent.height + 10
                                radius: height / 2
                                color: root.mauve
                                opacity: root.uiAnimating ? 0.6 : 0.0
                                scale: root.uiAnimating ? 1.0 : 0.5
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    blurEnabled: true
                                    blurMax: 32
                                    blur: 1.0
                                }
                                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            }
    
                            Text {
                                id: clockText
                                property var now: new Date()
                                text: Qt.formatDateTime(now, "HH:mm")
                                color: root.uiAnimating ? root.mauve : root.blue
                                font.family: root.font
                                font.pixelSize: 12
                                font.bold: true
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Timer {
                                    interval: 1000
                                    running: true
                                    repeat: true
                                    onTriggered: clockText.now = new Date()
                                }
                            }
                        }
    
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10
    
                            // Launcher button
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: ""
                                color: root.launcherOpen ? root.mauve : root.subtext
                                font.family: root.font
                                font.pixelSize: 15
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.launcherOpen = !root.launcherOpen
                                }
                            }
    
                            // Music button
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: ""
                                color: root.musicOpen ? root.mauve : root.subtext
                                font.family: root.font
                                font.pixelSize: 15
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.musicOpen = !root.musicOpen;
                                        if (root.musicOpen && root.musicTab === "library") root.reloadLibrary();
                                    }
                                }
                            }
    
                            // Workspaces
                            Row {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 4
                                Repeater {
                                    model: [ 1, 2, 3, 4, 5 ]
                                    delegate: Rectangle {
                                        required property int modelData
                                        property var ws: root.wsFor(modelData)
                                        width: 22
                                        height: 20
                                        radius: root.radius
                                        color: (ws && ws.focused) ? root.mauve
                                             : (ws && ws.active)  ? root.surface1
                                             : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: (ws && ws.focused) ? root.base
                                                 : ws ? root.text : root.overlay
                                            font.family: root.font
                                            font.pixelSize: 12
                                            font.bold: ws ? ws.focused : false
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: Hyprland.dispatch("workspace " + modelData)
                                        }
                                    }
                                }
                            }
    
                            // Active window title
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.maximumWidth: 340
                                text: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : ""
                                color: root.subtext
                                elide: Text.ElideRight
                                font.family: root.font
                                font.pixelSize: 12
                            }
    
                            Item { Layout.fillWidth: true }
    
                            // ---- right widgets ----
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰔄 " + (root.stats.TEMP ?? "--") + "°"; color: root.peach;  font.family: root.font; font.pixelSize: 12 }
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰻠 " + (root.stats.CPU ?? "--") + "%"; color: root.yellow; font.family: root.font; font.pixelSize: 12 }
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰍛 " + (root.stats.MEM ?? "--") + "%"; color: root.green;  font.family: root.font; font.pixelSize: 12 }
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰋊 " + (root.stats.DISK ?? "--") + "%"; color: root.teal;  font.family: root.font; font.pixelSize: 12 }
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰖩 " + (root.stats.NET ?? "--");        color: root.sky;   font.family: root.font; font.pixelSize: 12 }
    
                            // Volume
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                property var sink: Pipewire.defaultAudioSink
                                property bool muted: sink && sink.audio ? sink.audio.muted : false
                                property real vol: sink && sink.audio ? sink.audio.volume : 0
                                text: muted ? "󰝟" : "󰕾 " + Math.round(vol * 100) + "%"
                                color: muted ? root.overlay : root.mauve
                                font.family: root.font
                                font.pixelSize: 12
                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (m) => { if (sink && sink.audio && m.button === Qt.RightButton) sink.audio.muted = !sink.audio.muted; }
                                    onWheel: (w) => {
                                        if (sink && sink.audio)
                                            sink.audio.volume = Math.max(0, Math.min(1, sink.audio.volume + (w.angleDelta.y > 0 ? 0.05 : -0.05)));
                                    }
                                }
                            }
    
                            // Backlight
                            Text { Layout.alignment: Qt.AlignVCenter; text: "󰃠 " + (root.stats.BRIGHT ?? "--") + "%"; color: root.yellow; font.family: root.font; font.pixelSize: 12 }
    
                            // Battery
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                property var bat: UPower.displayDevice
                                property bool ready: bat ? bat.isLaptopBattery : false
                                visible: ready
                                text: {
                                    if (!bat) return "";
                                    const p = Math.round((bat.percentage ?? 0) * 100);
                                    const charging = bat.state === UPowerDeviceState.Charging;
                                    return (charging ? "󰂄 " : "󰁹 ") + p + "%";
                                }
                                color: {
                                    if (!bat) return root.green;
                                    const p = bat.percentage ?? 1;
                                    return p <= 0.15 ? root.red : p <= 0.3 ? root.peach : root.green;
                                }
                                font.family: root.font
                                font.pixelSize: 12
                            }
    
                            // System tray
                            Row {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 6
                                Repeater {
                                    model: SystemTray.items
                                    delegate: Image {
                                        required property var modelData
                                        width: 16
                                        height: 16
                                        source: modelData.icon
                                        sourceSize.width: 16
                                        sourceSize.height: 16
                                        fillMode: Image.PreserveAspectFit
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: modelData.activate()
                                            onPressed: (m) => {
                                                if (m.button === Qt.RightButton && modelData.hasMenu)
                                                    modelData.display(perScreen, m.x, m.y);
                                            }
                                        }
                                    }
                                }
                            }
    
                            // Notification bell
                            Item {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: bell.implicitWidth
                                implicitHeight: bell.implicitHeight
                                property int count: notifServer.trackedNotifications.values.length
                                Text {
                                    id: bell
                                    text: parent.count > 0 ? "󰂚" : "󰂜"
                                    color: parent.count > 0 ? root.mauve : root.subtext
                                    font.family: root.font
                                    font.pixelSize: 14
                                }
                                Rectangle {
                                    visible: parent.count > 0
                                    anchors { right: parent.right; top: parent.top; rightMargin: -5; topMargin: -5 }
                                    width: 14
                                    height: 14
                                    radius: 7
                                    color: root.red
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.parent.count
                                        color: root.base
                                        font.family: root.font
                                        font.pixelSize: 9
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.notifCenterOpen = !root.notifCenterOpen
                                }
                            }
    
                            // Power / session menu button
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: ""
                                color: root.menuOpen ? root.red : root.subtext
                                font.family: root.font
                                font.pixelSize: 15
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.menuOpen = !root.menuOpen
                                }
                            }
                        }
                    }
                }
    
                // ==================== NOTIFICATION CENTER ====================
                PanelWindow {
                    id: center
                    property bool shown: root.notifCenterOpen && perScreen.isFocused
                    property bool transitioning: false
                    onShownChanged: { transitioning = true; root.uiAnimating = true; uiAnimTimer.restart(); }
                    property real contentH: Math.min(560, centerCol.implicitHeight + 24)
                    screen: perScreen.modelData
                    visible: shown || transitioning
                    anchors { top: true; right: true }
                    margins { top: root.barHeight + 6; right: 10 }
                    implicitWidth: 360
                    implicitHeight: (42 - (root.barHeight + 6)) + contentH
                    color: "transparent"
                    aboveWindows: true
                    exclusiveZone: 0
    
                    Item {
                    id: centerSurface
                    anchors.fill: parent
    
                    Rectangle {
                        id: centerBox
                        anchors.fill: parent
                        anchors.topMargin: (42 - (root.barHeight + 6))
                        radius: root.radius
                        color: Qt.rgba(0.067, 0.067, 0.102, 0.96)
                        border.width: 1
                        border.color: root.surface0
    
                        ColumnLayout {
                            id: centerCol
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 10
    
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "Notifications"; color: root.text; font.bold: true; font.family: root.font; font.pixelSize: 14 }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: "Clear all"
                                    color: root.mauve
                                    font.family: root.font
                                    font.pixelSize: 12
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: notifServer.trackedNotifications.values.slice().forEach(n => n.dismiss())
                                    }
                                }
                            }
    
                            ListView {
                                id: notifList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 8
                                model: notifServer.trackedNotifications
                                delegate: Rectangle {
                                    id: notifItem
                                    required property var modelData
                                    width: notifList.width
                                    implicitHeight: itemLayout.implicitHeight + 16
                                    radius: root.radius
                                    color: root.surface0
    
                                    RowLayout {
                                        id: itemLayout
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 8
    
                                        ClippingRectangle {
                                            Layout.alignment: Qt.AlignTop
                                            implicitWidth: 40
                                            implicitHeight: 40
                                            radius: root.radius
                                            color: root.base
                                            visible: root.notifPic(notifItem.modelData) !== ""
                                            Image {
                                                anchors.fill: parent
                                                source: root.notifPic(notifItem.modelData)
                                                sourceSize.width: 40
                                                sourceSize.height: 40
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            Text {
                                                Layout.fillWidth: true
                                                text: notifItem.modelData.summary ?? ""
                                                color: root.text
                                                font.bold: true
                                                font.family: root.font
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: notifItem.modelData.body ?? ""
                                                color: root.subtext
                                                font.family: root.font
                                                font.pixelSize: 11
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 4
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Text {
                                            text: "󰅖"
                                            color: root.overlay
                                            font.family: root.font
                                            font.pixelSize: 12
                                            Layout.alignment: Qt.AlignTop
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: notifItem.modelData.dismiss()
                                            }
                                        }
                                    }
                                }
                            }
    
                            Text {
                                visible: notifServer.trackedNotifications.values.length === 0
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: "No notifications"
                                color: root.overlay
                                font.family: root.font
                                font.pixelSize: 12
                            }
                        }
                    }
    
                    Genie {
                        id: centerGenie
                        anchors.fill: centerBox
                        sourceItem: centerBox
                        edge: Genie.TopEdge
                        targetX: width + 10 - perScreen.modelData.width / 2
                        targetY: -21
                        neckWidth: 0.4
                        minimized: !center.shown
                        opacity: 1
                        onFinished: center.transitioning = false
                        source: ShaderEffectSource {
                            sourceItem: centerBox
                            hideSource: center.transitioning
                            live: true
                        }
                    }
                    }
                }
    
                // ============================ TOAST ============================
                PanelWindow {
                    id: toastWin
                    property bool shown: root.toast !== null && !root.notifCenterOpen && perScreen.isFocused
                    property bool transitioning: false
                    onShownChanged: { transitioning = true; root.uiAnimating = true; uiAnimTimer.restart(); }
                    property real contentH: toastCol.implicitHeight + 20
                    screen: perScreen.modelData
                    visible: shown || transitioning
                    anchors { top: true; right: true }
                    margins { top: root.barHeight + 6; right: 10 }
                    implicitWidth: 340
                    implicitHeight: (42 - (root.barHeight + 6)) + contentH
                    color: "transparent"
                    aboveWindows: true
                    exclusiveZone: 0
    
                    Item {
                    id: toastSurface
                    anchors.fill: parent
    
                    Rectangle {
                        id: toastBox
                        anchors.fill: parent
                        anchors.topMargin: (42 - (root.barHeight + 6))
                        radius: root.radius
                        color: Qt.rgba(0.094, 0.094, 0.149, 0.97)
                        border.width: 1
                        border.color: root.surface0
    
                        RowLayout {
                            id: toastCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 8
                            ClippingRectangle {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: 40
                                implicitHeight: 40
                                radius: root.radius
                                color: root.base
                                visible: root.notifPic(root.toast) !== ""
                                Image {
                                    anchors.fill: parent
                                    source: root.notifPic(root.toast)
                                    sourceSize.width: 40
                                    sourceSize.height: 40
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: root.toast ? (root.toast.summary ?? "") : ""
                                    color: root.text
                                    font.bold: true
                                    font.family: root.font
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.toast ? (root.toast.body ?? "") : ""
                                    color: root.subtext
                                    font.family: root.font
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: { root.toast = null; root.notifCenterOpen = true; }
                        }
                    }
    
                    Genie {
                        anchors.fill: toastBox
                        sourceItem: toastBox
                        edge: Genie.TopEdge
                        targetX: width + 10 - perScreen.modelData.width / 2
                        targetY: -21
                        neckWidth: 0.4
                        minimized: !toastWin.shown
                        opacity: 1
                        onFinished: toastWin.transitioning = false
                        source: ShaderEffectSource {
                            sourceItem: toastBox
                            hideSource: toastWin.transitioning
                            live: true
                        }
                    }
                    }
                }
    
                // ======================= LAUNCHER =======================
                PanelWindow {
                    id: launcher
                    property bool shown: root.launcherOpen && perScreen.isFocused
                    property bool transitioning: false
                    onShownChanged: { transitioning = true; root.uiAnimating = true; uiAnimTimer.restart(); }
                    property real contentH: 400
                    screen: perScreen.modelData
                    visible: shown || transitioning
                    anchors { top: true; left: true; right: true }
                    margins { top: root.barHeight + 6 }
                    implicitHeight: (90 - (root.barHeight + 6)) + contentH
                    color: "transparent"
                    aboveWindows: true
                    focusable: true
                    exclusiveZone: 0
    
                    Item {
                    id: launcherSurface
                    anchors.fill: parent
    
                    Rectangle {
                        id: launcherBox
                        width: 560
                        height: launcher.contentH
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        radius: root.radius
                        color: Qt.rgba(0.067, 0.067, 0.102, 0.97)
                        border.width: 1
                        border.color: root.surface0
    
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 10
    
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 38
                                radius: root.radius
                                color: root.base
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    spacing: 8
                                    Text { text: ""; color: root.mauve; font.family: root.font; font.pixelSize: 15 }
                                    TextInput {
                                        id: searchInput
                                        Layout.fillWidth: true
                                        color: root.text
                                        font.family: root.font
                                        font.pixelSize: 13
                                        selectByMouse: true
                                        focus: root.launcherOpen && perScreen.isFocused
                                        onTextChanged: root.query = text
                                        onAccepted: {
                                            if (root.results.length > 0) {
                                                root.results[0].execute();
                                                root.launcherOpen = false;
                                            }
                                        }
                                        Keys.onEscapePressed: root.launcherOpen = false
                                    }
                                }
                            }
    
                            ListView {
                                id: appList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 4
                                model: root.results
                                delegate: Rectangle {
                                    id: appItem
                                    required property var modelData
                                    width: appList.width
                                    implicitHeight: 42
                                    radius: root.radius
                                    color: appMouse.containsMouse ? root.surface0 : "transparent"
    
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        spacing: 10
                                        Image {
                                            source: Quickshell.iconPath(appItem.modelData.icon, true)
                                            sourceSize.width: 22
                                            sourceSize.height: 22
                                            width: 22
                                            height: 22
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text {
                                                text: appItem.modelData.name ?? ""
                                                color: root.text
                                                font.family: root.font
                                                font.pixelSize: 12
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: appItem.modelData.comment ?? ""
                                                color: root.overlay
                                                font.family: root.font
                                                font.pixelSize: 10
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                    MouseArea {
                                        id: appMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            appItem.modelData.execute();
                                            root.launcherOpen = false;
                                        }
                                    }
                                }
                            }
    
                            Text {
                                visible: root.results.length === 0
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: "No results"
                                color: root.overlay
                                font.family: root.font
                                font.pixelSize: 12
                            }
                        }
                    }
    
                    Genie {
                        anchors.fill: launcherBox
                        sourceItem: launcherBox
                        edge: Genie.TopEdge
                        targetX: perScreen.modelData.width / 2
                        targetY: -69
                        neckWidth: 0.4
                        minimized: !launcher.shown
                        opacity: 1
                        onFinished: launcher.transitioning = false
                        source: ShaderEffectSource {
                            sourceItem: launcherBox
                            hideSource: launcher.transitioning
                            live: true
                        }
                    }
                    }
                }
    
                // ===================== SYSTEM MENU ======================
                PanelWindow {
                    id: sysmenu
                    property bool shown: root.menuOpen && perScreen.isFocused
                    property bool transitioning: false
                    onShownChanged: { transitioning = true; root.uiAnimating = true; uiAnimTimer.restart(); }
                    property real contentH: menuCol.implicitHeight + 20
                    screen: perScreen.modelData
                    visible: shown || transitioning
                    anchors { top: true; right: true }
                    margins { top: root.barHeight + 6; right: 10 }
                    implicitWidth: 200
                    implicitHeight: (42 - (root.barHeight + 6)) + contentH
                    color: "transparent"
                    aboveWindows: true
                    exclusiveZone: 0
    
                    Item {
                        id: menuSurface
                        anchors.fill: parent
    
                        Rectangle {
                            id: menuBox
                            anchors.fill: parent
                            anchors.topMargin: (42 - (root.barHeight + 6))
                            radius: root.radius
                            color: Qt.rgba(0.067, 0.067, 0.102, 0.97)
                            border.width: 1
                            border.color: root.surface0
    
                            ColumnLayout {
                                id: menuCol
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 4
    
                                Repeater {
                                    model: [
                                        { label: "Lock",     icon: "󰌾", act: () => Quickshell.execDetached([ "hyprlock", "--config", "/etc/xdg/hypr/hyprlock.conf" ]) },
                                        { label: "Logout",   icon: "󰍃", act: () => Hyprland.dispatch("exit") },
                                        { label: "Suspend",  icon: "󰒲", act: () => Quickshell.execDetached([ "systemctl", "suspend" ]) },
                                        { label: "Reboot",   icon: "󰜉", act: () => Quickshell.execDetached([ "systemctl", "reboot" ]) },
                                        { label: "Shutdown", icon: "󰐥", act: () => Quickshell.execDetached([ "systemctl", "poweroff" ]) }
                                    ]
                                    delegate: Rectangle {
                                        id: menuItem
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: 34
                                        radius: root.radius
                                        color: menuMouse.containsMouse ? root.surface1 : root.surface0
    
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            spacing: 10
                                            Text { text: menuItem.modelData.icon; color: root.mauve; font.family: root.font; font.pixelSize: 15 }
                                            Text { text: menuItem.modelData.label; color: root.text; font.family: root.font; font.pixelSize: 12; Layout.fillWidth: true }
                                        }
                                        MouseArea {
                                            id: menuMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: {
                                                menuItem.modelData.act();
                                                root.menuOpen = false;
                                            }
                                        }
                                    }
                                }
                            }
                        }
    
                        Genie {
                            anchors.fill: menuBox
                            sourceItem: menuBox
                            edge: Genie.TopEdge
                            targetX: width + 10 - perScreen.modelData.width / 2
                            targetY: -21
                            neckWidth: 0.4
                            minimized: !sysmenu.shown
                            opacity: 1
                            onFinished: sysmenu.transitioning = false
                            source: ShaderEffectSource {
                                sourceItem: menuBox
                                hideSource: sysmenu.transitioning
                                live: true
                            }
                        }
                    }
                }
    
                // ============================ MUSIC ============================
                PanelWindow {
                    id: music
                    property bool shown: root.musicOpen && perScreen.isFocused
                    property bool transitioning: false
                    onShownChanged: { transitioning = true; root.uiAnimating = true; uiAnimTimer.restart(); }
                    property real contentH: 470
                    screen: perScreen.modelData
                    visible: shown || transitioning
                    anchors { top: true; left: true; right: true }
                    margins { top: root.barHeight + 6 }
                    implicitHeight: (90 - (root.barHeight + 6)) + contentH
                    color: "transparent"
                    aboveWindows: true
                    focusable: true
                    exclusiveZone: 0
    
                    Item {
                    id: musicSurface
                    anchors.fill: parent
    
                    Rectangle {
                        id: musicBox
                        width: 620
                        height: music.contentH
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        radius: root.radius
                        color: Qt.rgba(0.067, 0.067, 0.102, 0.97)
                        border.width: 1
                        border.color: root.surface0
    
                        // Keyboard focus target for the library tab (search tab is handled by the TextInput).
                        FocusScope {
                            id: musicKeys
                            anchors.fill: parent
                            focus: root.musicOpen && root.musicTab === "library" && perScreen.isFocused
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: (e) => root.musicKey(e, true)
                        }
    
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 10
    
                            // ---- tabs + search ----
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
    
                                Rectangle {
                                    implicitWidth: 84; implicitHeight: 32; radius: root.radius
                                    color: root.musicTab === "search" ? root.mauve : root.surface0
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Text { anchors.centerIn: parent; text: "Search"; color: root.musicTab === "search" ? root.base : root.text; font.family: root.font; font.pixelSize: 12 }
                                    MouseArea { anchors.fill: parent; onClicked: { root.musicTab = "search"; root.musicSel = -1; } }
                                }
                                Rectangle {
                                    implicitWidth: 84; implicitHeight: 32; radius: root.radius
                                    color: root.musicTab === "library" ? root.mauve : root.surface0
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Text { anchors.centerIn: parent; text: "Library"; color: root.musicTab === "library" ? root.base : root.text; font.family: root.font; font.pixelSize: 12 }
                                    MouseArea { anchors.fill: parent; onClicked: { root.musicTab = "library"; root.musicSel = -1; root.reloadLibrary(); } }
                                }
    
                                Rectangle {
                                    visible: root.musicTab === "search"
                                    Layout.fillWidth: true
                                    implicitHeight: 32
                                    radius: root.radius
                                    color: root.base
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        spacing: 8
                                        Text { text: ""; color: root.mauve; font.family: root.font; font.pixelSize: 14 }
                                        TextInput {
                                            id: musicSearchInput
                                            Layout.fillWidth: true
                                            color: root.text
                                            font.family: root.font
                                            font.pixelSize: 12
                                            selectByMouse: true
                                            focus: root.musicOpen && root.musicTab === "search" && perScreen.isFocused
                                            onTextChanged: root.musicQuery = text
                                            Keys.priority: Keys.BeforeItem
                                            Keys.onPressed: (e) => root.musicKey(e, false)
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "Search YouTube…"
                                                color: root.overlay
                                                font.family: root.font
                                                font.pixelSize: 12
                                                visible: musicSearchInput.text === ""
                                            }
                                        }
                                        Text { text: "⏎"; color: root.overlay; font.family: root.font; font.pixelSize: 12 }
                                    }
                                }
    
                                RowLayout {
                                    visible: root.downloading
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 6
                                    Text {
                                        text: "󰇚"; color: root.mauve; font.family: root.font; font.pixelSize: 13
                                        SequentialAnimation on opacity {
                                            running: root.downloading
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.3; duration: 600 }
                                            NumberAnimation { to: 1.0; duration: 600 }
                                        }
                                    }
                                    Text { text: "downloading"; color: root.mauve; font.family: root.font; font.pixelSize: 10 }
                                }
    
                                Row {
                                    visible: root.musicTab === "library"
                                    Layout.preferredWidth: 24
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 2
                                    Repeater {
                                        model: 3
                                        Rectangle {
                                            required property int index
                                            width: 3
                                            radius: 1.5
                                            color: root.mauve
                                            anchors.verticalCenter: parent.verticalCenter
                                            height: 5
                                            SequentialAnimation on height {
                                                running: !root.nowPaused
                                                loops: Animation.Infinite
                                                NumberAnimation { to: 15 - index * 3; duration: 320 + index * 80; easing.type: Easing.InOutSine }
                                                NumberAnimation { to: 4 + index; duration: 320 + index * 80; easing.type: Easing.InOutSine }
                                            }
                                        }
                                    }
                                }
                            }
    
                            // ---- list ----
                            ListView {
                                id: musicList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 4
                                model: root.musicTab === "library" ? root.musicLibrary : root.musicResults
                                delegate: Rectangle {
                                    id: musicItem
                                    required property var modelData
                                    required property int index
                                    width: musicList.width
                                    implicitHeight: 44
                                    radius: root.radius
                                    color: index === root.musicSel ? root.surface1
                                         : (mMusic.containsMouse ? root.surface0 : "transparent")
                                    Behavior on color { ColorAnimation { duration: 120 } }
    
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        spacing: 10
                                        Text { text: ""; color: root.mauve; font.family: root.font; font.pixelSize: 14 }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text {
                                                Layout.fillWidth: true
                                                text: root.musicTab === "library" ? (musicItem.modelData.name || "") : (musicItem.modelData.title || "")
                                                color: index === root.musicSel ? root.mauve : root.text
                                                font.family: root.font
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                visible: root.musicTab === "search"
                                                text: {
                                                    if (root.musicTab !== "search") return "";
                                                    const d = parseInt(musicItem.modelData.duration || "0");
                                                    const mm = Math.floor(d / 60), ss = d % 60;
                                                    const dur = d > 0 ? (mm + ":" + (ss < 10 ? "0" : "") + ss) : "";
                                                    return (musicItem.modelData.uploader || "") + (dur ? "  ·  " + dur : "");
                                                }
                                                color: root.overlay
                                                font.family: root.font
                                                font.pixelSize: 10
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Item {
                                            visible: root.musicTab === "search"
                                            implicitWidth: 20; implicitHeight: 20
                                            Text { anchors.centerIn: parent; text: "󰇚"; color: mMusic.containsMouse && mMusic.mouseX > mMusic.width - 34 ? root.mauve : root.overlay; font.family: root.font; font.pixelSize: 15 }
                                        }
                                    }
                                    MouseArea {
                                        id: mMusic
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: (m) => {
                                            if (root.musicTab === "search" && m.x > width - 34) {
                                                root.musicDownload(musicItem.modelData.id);
                                            } else if (root.musicTab === "library") {
                                                root.musicPlayLibrary(musicItem.index);
                                            } else {
                                                root.musicPlayResult(musicItem.index);
                                            }
                                        }
                                    }
                                }
                            }
    
                            Text {
                                visible: (root.musicTab === "library" ? root.musicLibrary.length : root.musicResults.length) === 0
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.musicTab === "library" ? "Library empty — download some songs" : "Search for music above"
                                color: root.overlay
                                font.family: root.font
                                font.pixelSize: 11
                            }
    
                            // ---- now playing ----
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 76
                                radius: root.radius
                                color: root.surface0
    
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 10
    
                                    ClippingRectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: 58
                                        implicitHeight: 58
                                        radius: root.radius
                                        color: root.base
                                        Image {
                                            id: coverImg
                                            anchors.fill: parent
                                            source: root.coverSource !== "" ? "file://" + root.coverSource : ""
                                            sourceSize.width: 58
                                            sourceSize.height: 58
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            opacity: status === Image.Ready ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            visible: coverImg.status !== Image.Ready
                                            text: "󰎆"
                                            color: root.mauve
                                            font.family: root.font
                                            font.pixelSize: 22
                                        }
                                    }
    
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 4
    
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                Layout.fillWidth: true
                                                text: root.nowTitle !== "" ? root.nowTitle : "Nothing playing"
                                                color: root.text
                                                font.bold: true
                                                font.family: root.font
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                text: root.nowArtist
                                                color: root.subtext
                                                font.family: root.font
                                                font.pixelSize: 10
                                                elide: Text.ElideRight
                                                Layout.maximumWidth: 170
                                                visible: root.nowArtist !== ""
                                            }
                                        }
    
                                        Rectangle {
                                            id: progTrack
                                            Layout.fillWidth: true
                                            implicitHeight: 6
                                            radius: 3
                                            color: root.base
                                            Rectangle {
                                                width: root.nowDuration > 0 ? Math.max(0, Math.min(progTrack.width, progTrack.width * root.nowPos / root.nowDuration)) : 0
                                                height: parent.height
                                                radius: 3
                                                color: root.mauve
                                                Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.Linear } }
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: (m) => root.musicSeekTo(m.x / width)
                                            }
                                        }
    
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Text { text: root.fmtTime(root.nowPos); color: root.overlay; font.family: root.font; font.pixelSize: 9 }
                                            Item { Layout.fillWidth: true }
                                            Text { text: root.fmtTime(root.nowDuration); color: root.overlay; font.family: root.font; font.pixelSize: 9 }
                                        }
                                    }
    
                                    RowLayout {
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 12
                                        Text {
                                            text: "󰒮"; color: root.subtext; font.family: root.font; font.pixelSize: 18
                                            MouseArea { anchors.fill: parent; onClicked: root.musicPrev() }
                                        }
                                        Text {
                                            text: root.nowPaused ? "󰐊" : "󰏤"; color: root.mauve; font.family: root.font; font.pixelSize: 22
                                            MouseArea { anchors.fill: parent; onClicked: root.musicToggle() }
                                        }
                                        Text {
                                            text: "󰒭"; color: root.subtext; font.family: root.font; font.pixelSize: 18
                                            MouseArea { anchors.fill: parent; onClicked: root.musicNext() }
                                        }
                                        Text {
                                            text: "󰓛"; color: root.red; font.family: root.font; font.pixelSize: 16
                                            MouseArea { anchors.fill: parent; onClicked: Quickshell.execDetached([ "qs-music", "stop" ]) }
                                        }
                                    }
                                }
                            }
                        }
                    }
    
                    Genie {
                        anchors.fill: musicBox
                        sourceItem: musicBox
                        edge: Genie.TopEdge
                        targetX: perScreen.modelData.width / 2
                        targetY: -69
                        neckWidth: 0.4
                        minimized: !music.shown
                        opacity: 1
                        onFinished: music.transitioning = false
                        source: ShaderEffectSource {
                            sourceItem: musicBox
                            hideSource: music.transitioning
                            live: true
                        }
                    }
                    }
                }
            }
        }
    }
  '';















  # ===========================================================================
  #  Neovim config (from KaydenVRH/MacOS-rice; adapted: Catppuccin Mocha + NixOS)
  # ===========================================================================
  nvimInit = ''
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
  '';

  nvimRainbow = ''
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
  '';

in
{
  # ---------------------------------------------------------------------------
  #  Compositor
  # ---------------------------------------------------------------------------
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # ---------------------------------------------------------------------------
  #  Session environment (cursor fix + Wayland hints)
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    # Force Hyprland to use the rice config, instead of the auto-generated
    # default it drops in ~/.config/hypr/hyprland.lua on first launch.
    HYPRLAND_CONFIG   = "/etc/xdg/hypr/hyprland.lua";
    XCURSOR_THEME     = cursorTheme;
    XCURSOR_SIZE      = "24";
    HYPRCURSOR_THEME  = cursorTheme;
    HYPRCURSOR_SIZE   = "24";
    NIXOS_OZONE_WL    = "1";
    GTK_THEME         = gtkTheme;
    # Apps that open URLs (e.g. Prism Launcher login) use this.
    BROWSER           = "firefox";
  };

  # ---------------------------------------------------------------------------
  #  Packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # compositor helpers
    swaybg
    hyprpicker
    wl-clipboard
    grim
    slurp
    brightnessctl
    playerctl

    # desktop apps
    kitty
    nemo
    rofi
    quickshell
    hyprlock
    librewolf
    networkmanagerapplet
    pavucontrol

    # neovim toolchain (lazy.nvim plugins, treesitter builds, LSP servers)
    git
    fd
    ripgrep
    unzip
    curl
    wget
    lazygit
    mpv
    netcat-openbsd
    tree-sitter
    gcc
    gnumake
    nodejs
    go
    python3
    lua-language-server
    bash-language-server
    pyright
    gopls

    # music player (quickshell panel) tools
    musicScript
    yt-dlp
    ffmpeg
    jq

    # fonts, theme + cursor
    nerd-fonts.jetbrains-mono
    catppuccin-cursors.mochaDark
    catppuccinGtk
  ];

  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # ---------------------------------------------------------------------------
  #  Generated config files (all live inside this one module)
  # ---------------------------------------------------------------------------
  environment.etc = {
    "xdg/hypr/hyprland.lua".text = hyprlandLua;
    "xdg/hypr/hyprlock.conf".text = hyprlockConf;
    "xdg/hypr/wallpaper.png".source = wallpaperPng;

    "xdg/quickshell/rice/shell.qml".text = quickshellQml;

    "xdg/rofi/config.rasi".text = rofiConfig;
    "xdg/kitty/kitty.conf".text = kittyConf;

    # Neovim (read system-wide via XDG_CONFIG_DIRS)
    "xdg/nvim/init.lua".text = nvimInit;
    "xdg/nvim/lua/rainbow.lua".text = nvimRainbow;

    # GTK theme for GTK3/GTK4 apps (thunar, pavucontrol, nm-applet, swaync...)
    "gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name = ${gtkTheme}
      gtk-application-prefer-dark-theme = 1
    '';
    "gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name = ${gtkTheme}
      gtk-application-prefer-dark-theme = 1
    '';
  };

  # ---------------------------------------------------------------------------
  #  Session daemons as systemd user services.
  #
  #  Why not Hyprland's `exec-once`? At login the Wayland socket / imported
  #  environment is not ready yet, so the shell silently dies. Systemd starts
  #  these at login and restarts them until the Hyprland session has imported
  #  its environment, at which point they connect successfully.
  # ---------------------------------------------------------------------------
  systemd.user.services = {
    swaybg = {
      description = "swaybg wallpaper";
      wantedBy = [ "default.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${pkgs.swaybg}/bin/swaybg -i /etc/xdg/hypr/wallpaper.png -m fill";
        Restart = "always";
        RestartSec = 1;
      };
    };

    quickshell = {
      description = "Quickshell desktop shell";
      wantedBy = [ "default.target" ];
      startLimitIntervalSec = 0;
      environment = {
        QML_IMPORT_PATH = "${quickmotion}/lib/qt-6/qml";
        QML2_IMPORT_PATH = "${quickmotion}/lib/qt-6/qml";
      };
      serviceConfig = {
        ExecStart = "${waitForHyprland} ${pkgs.quickshell}/bin/quickshell -c rice";
        Restart = "always";
        RestartSec = 1;
      };
    };

    nm-applet = {
      description = "NetworkManager applet";
      wantedBy = [ "default.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${pkgs.networkmanagerapplet}/bin/nm-applet --indicator";
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
