# shellcheck shell=bash disable=SC2034
# settings.sh: the settings registry, its readers and its writers.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── SETTINGS — curated, individually-editable fields (not whole files) ─────
# Unlike MANIFEST (whole files, tracked for backup/sync), each entry here is one
# single field inside an already-tracked file, safe to read and write
# mechanically. The panel renders a control per type, so adding a setting is one
# line here and no QML change.
#
# Format: "id|group|file|path|type|label|unit|min|max|options|hint|apply|fallback|scale|display"
#
#   group    the section the panel files this control under
#   file     the file holding the value ("-" for types that don't read a file)
#   path     jq path (".idle.lock") for JSON | "section.key" for TOML |
#            the Hyprland option ("input:repeat_rate") for lua-*, whose last
#            segment is the Lua key and whose whole name is what Hyprland is
#            asked for the value in force | "-" for theme
#   type     number | bool | enum            JSON, via jq
#            toml-int | toml-float           "key = <n>" inside a [section]
#            lua-int | lua-bool | lua-enum   a "key = value" line in a Hyprland
#                                            Lua config (see lua_get for limits)
#            theme                           the active Omarchy theme
#            line-enum                       a file holding one bare word
#   min/max  numeric types only, in the STORED unit
#   options  enum types only, comma-separated
#   hint     one short line shown under the control
#   apply    command run after a successful write. Empty means the value is
#            picked up live: the Omarchy shell watches both shell.json and
#            ~/.config/omarchy/shell.toml (FileView watchChanges), so those
#            need nothing. Hyprland does not, hence `hyprctl reload`.
#   fallback the value in force when the key is absent from the file, i.e. the
#            shell's own built-in default. Only for keys the writer can create
#            (the toml-* types): shell.toml ships nearly empty, so most
#            appearance keys are missing until you change one, and reporting
#            them as "unavailable" would leave a control the user can see but
#            never touch. Reported with implicit:true so the panel can say the
#            value is inherited rather than written down anywhere. It doubles as
#            the value "reset to the Omarchy default" writes when the file
#            Omarchy ships has nothing to read.
#   scale    stored-unit -> shown-unit divisor. Omarchy stores idle timers in
#            seconds; nobody thinks in "600 seconds", so the panel edits them in
#            minutes (scale 60) and multiplies back before writing. Empty or 1
#            means the two units are the same. The CLI always speaks the STORED
#            unit — `set idle.lock 600` is still seconds — so scripts do not
#            have to know what the panel happens to display.
#   display  the unit shown next to the control once `scale` is applied
#            ("min"). Empty falls back to `unit`.
#
# A setting whose file or key is missing on this machine reads as null and the
# panel greys the control out. That is the intended behaviour, not an error:
# these files are the user's own and no two machines carry the same keys.
SETTINGS=(
  # ── Idle & power — ~/.config/omarchy/shell.json, watched live by the shell.
  # Stored in seconds by Omarchy, edited in minutes here.
  "idle.screensaver|Idle & power|$HOME/.config/omarchy/shell.json|.idle.screensaver|number|Screensaver|s|60|3600||Idle time before the screensaver starts|||60|min"
  "idle.lock|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lock|number|Lock screen|s|60|7200||Idle time before the screen locks|||60|min"
  "idle.lazyDpms|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazyDpms|number|Turn off display|s|60|7200||Idle time before the display powers down|||60|min"
  "idle.lazySuspendAc|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendAc|number|Suspend on AC|s|0|14400||Idle time before suspending on AC power (0 = never)|||60|min"
  "idle.lazySuspendBatt|Idle & power|$HOME/.config/omarchy/shell.json|.idle.lazySuspendBatt|number|Suspend on battery|s|0|14400||Idle time before suspending on battery (0 = never)|||60|min"
  # ── Appearance
  "theme.current|Appearance|-|-|theme|Theme|||||The theme applied to the shell, terminals and editor||tokyo-night|1|"
  "bar.position|Appearance|$HOME/.config/omarchy/shell.json|.bar.position|enum|Bar position||||top,bottom,left,right|Which screen edge the status bar sits on|||1|"
  "bar.transparent|Appearance|$HOME/.config/omarchy/shell.json|.bar.transparent|bool|Transparent bar|||||Let the wallpaper show through the bar|||1|"
  "font.baseSize|Appearance|$HOME/.config/omarchy/shell.toml|font.base-size|toml-int|Interface font size|pt|8|32||Base size every bar, menu and panel font derives from||12|1|"
  "spacing.scale|Appearance|$HOME/.config/omarchy/shell.toml|spacing.scale|toml-float|Interface density|×|0.5|2||Multiplies every margin, gap and control size||1.0|1|"
  "bar.sizeHorizontal|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-horizontal|toml-int|Bar thickness (top/bottom)|px|16|80||Bar height on a horizontal edge; setting it stops the font scaling it||26|1|"
  "bar.sizeVertical|Appearance|$HOME/.config/omarchy/shell.toml|bar.size-vertical|toml-int|Bar thickness (left/right)|px|16|120||Bar width on a vertical edge; setting it stops the font scaling it||28|1|"
  "bar.iconFont|Appearance|$HOME/.config/omarchy/shell.toml|bar.icon-font|toml-int|Bar icon size|px|8|28||How large the glyphs in the bar are drawn||13|1|"
  # ── Input — Hyprland reads Lua at startup, so these need an explicit reload
  "input.repeatRate|Input|$HOME/.config/hypr/input.lua|input:repeat_rate|lua-int|Key repeat rate|/s|1|100||Characters a held key sends per second|hyprctl reload||1|"
  "input.repeatDelay|Input|$HOME/.config/hypr/input.lua|input:repeat_delay|lua-int|Key repeat delay|ms|100|2000||How long a key is held before it starts repeating|hyprctl reload||1|"
  "input.kbLayout|Input|$HOME/.config/hypr/input.lua|input:kb_layout|lua-enum|Keyboard layout||||@x11-layouts|X11 layout code for the keyboard|hyprctl reload||1|"
  "input.numlock|Input|$HOME/.config/hypr/input.lua|input:numlock_by_default|lua-bool|Num lock at login|||||Turn the numeric keypad on when the session starts|hyprctl reload||1|"
  "input.naturalScroll|Input|$HOME/.config/hypr/input.lua|input:touchpad:natural_scroll|lua-bool|Natural scrolling|||||Touchpad: two fingers down moves the page up|hyprctl reload||1|"
  "input.tapToClick|Input|$HOME/.config/hypr/input.lua|input:touchpad:tap_to_click|lua-bool|Tap to click|||||Touchpad: a tap counts as a click|hyprctl reload||1|"
  "input.disableWhileTyping|Input|$HOME/.config/hypr/input.lua|input:touchpad:disable_while_typing|lua-bool|Ignore touchpad while typing|||||Stops the cursor jumping mid-sentence|hyprctl reload||1|"
  # ── Lid & sleep — /etc/systemd/logind.conf.d/, root-owned, laptop only.
  # These are the three questions a laptop actually asks. logind's own built-in
  # default for all three is 'suspend'; the fallback field records that so the
  # panel can show a value even before a drop-in exists.
  "lid.close|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitch|ini-enum|Closing the lid||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens on battery when the lid closes|systemctl reload systemd-logind|suspend|1|"
  "lid.closeAc|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchExternalPower|ini-enum|Closing the lid on AC||||suspend,suspend-then-hibernate,hibernate,lock,ignore,poweroff|What happens while plugged in; many people want 'ignore' here|systemctl reload systemd-logind|suspend|1|"
  "lid.closeDocked|Lid & sleep|$LOGIND_DROPIN|Login.HandleLidSwitchDocked|ini-enum|Closing the lid when docked||||ignore,suspend,suspend-then-hibernate,hibernate,lock,poweroff|What happens with an external monitor attached; 'ignore' is clamshell mode|systemctl reload systemd-logind|ignore|1|"
  # ── Defaults
  "default.editor|Defaults|$HOME/.local/state/omarchy/defaults/editor|-|line-enum|Default editor||||nvim,code,hx,micro,nano,zed|Editor Omarchy opens config files with||nvim|1|"
)

# Settings groups, in panel order: "name|icon|description"
SETTING_GROUPS=(
  "Idle & power|󰐥|When the screen dims, locks and the machine suspends"
  "Appearance|󰏘|Theme, bar and how large everything is drawn"
  "Input|󰌌|Keyboard and touchpad behaviour"
  "Lid & sleep|󰌢|What closing the lid does — shown on laptops only"
  "Defaults|󰒓|Which program Omarchy reaches for"
)


# Pure bash: `cut` here meant a fork per field, and the panel reads fifteen
# fields from twenty-odd settings on every refresh — three hundred processes
# for a string split.
setting_field() { local -a fields; IFS='|' read -ra fields <<<"$1"; printf '%s' "${fields[$(($2 - 1))]:-}"; }

find_setting() {
  local id="$1" entry
  # The id is the first field, so a prefix match finds it without a fork.
  # `$(setting_field ...)` here was one fork per registry line, and the panel
  # payload looks up every setting three times: hundreds of forks, and about
  # half of the time that `status --json` took.
  for entry in "${SETTINGS[@]}"; do
    [[ "${entry%%|*}" == "$id" ]] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

# root_apply <destination> <staged file> [command to run afterwards]
# Writes a staged file into a root-owned path, keeping the same .bak.<epoch>
# every other write in this plugin makes, and runs the reload in the SAME
# privileged call so the user is asked at most once.
#
# There is no silent path here. It tries, in order:
#   1. pkexec  — a graphical prompt, when the session runs a polkit agent
#   2. sudo -n — only if this user already has passwordless rights for it
#   3. nothing — prints the exact command and fails, leaving /etc untouched
# Omarchy ships no polkit agent by default, so (3) is the common outcome in the
# panel and (2)/(1) the common one from a terminal. Saying so is the point:
# a settings control that quietly does nothing is worse than one that explains.
root_apply() {
  local dst="$1" staged="$2" after="${3:-}" script
  script='dst="$1"; staged="$2"; after="$3";
    if [ -f "$dst" ]; then cp -a "$dst" "$dst.bak.$(date +%s)" || exit 1; fi
    install -D -m 644 -o root -g root "$staged" "$dst" || exit 1
    [ -n "$after" ] && { sh -c "$after" || exit 2; }
    exit 0'
  if command -v pkexec >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    pkexec /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null && return 0
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n /bin/sh -c "$script" _ "$dst" "$staged" "$after" 2>/dev/null && return 0
  fi
  echo "This one needs root, and nothing on this session could ask for it." >&2
  echo "Nothing was changed. To apply it yourself:" >&2
  echo "  sudo install -D -m 644 $staged $dst" >&2
  [[ -n "$after" ]] && echo "  sudo $after" >&2
  # Always a failure. This read `return "${rc:-1}"` with rc starting at 0, so
  # the path above returned success: `set` printed the new value, exited 0,
  # and the panel reported a write that never happened.
  return 1
}

# ini_set <file> <Section.Key> <value> [reload command]
# Stages the whole edited file under $HOME first, so the privileged step is a
# single copy of a file the user could have inspected, not an editor run as root.
ini_set() {
  invalidate_file_maps
  local file="$1" path="$2" value="$3" after="${4:-}" staged
  # Staged in the plugin's own directory, not in /tmp. When nothing can ask for
  # root, root_apply prints a `sudo install` of this file for the user to run,
  # so the file has to outlive this call. It used to be deleted on the way
  # out, and the printed command named a file that did not exist.
  mkdir -p "$REPLICANT_HOME/staged" || return 1
  staged="$REPLICANT_HOME/staged/$(basename -- "$file")"
  if [[ -f "$file" ]]; then cp -- "$file" "$staged"; else printf '[%s]\n' "${path%%.*}" > "$staged"; fi
  toml_set "$staged" "$path" "$value" || { rm -f "$staged"; return 1; }
  # toml_set keeps whatever spacing surrounded the '='; TOML writes `key = v`
  # and systemd writes `Key=v`. Normalise to systemd's idiom so a drop-in this
  # plugin has touched still reads like every other one on the machine.
  local k="${path#*.}"
  sed -i -E "s|^([[:space:]]*)${k}[[:space:]]*=[[:space:]]*|\1${k}=|" "$staged"
  if [[ -w "$file" || ( ! -e "$file" && -w "$(dirname "$file")" ) ]]; then
    backup_before_write "$file"
    install -D -m 644 "$staged" "$file" || { rm -f "$staged"; return 1; }
    # A test redirects $file to a throwaway fixture, but "systemctl reload
    # systemd-logind" still targets the REAL system service — polkit pops a
    # graphical, fingerprint-eligible auth prompt for it even though nothing
    # here calls sudo/pkexec directly. REPLICANT_NO_RELOAD is the test-only
    # escape hatch, the same shape as REPLICANT_MACHINE/OMARCHY_PATH elsewhere.
    [[ -n "$after" && -z "${REPLICANT_NO_RELOAD:-}" ]] && bash -c "$after" >/dev/null 2>&1
    rm -f "$staged"; return 0
  fi
  # On failure the staged file stays: the message names it.
  root_apply "$file" "$staged" "$after" || return 1
  rm -f "$staged"
}

# Only a machine with a lid should be offered lid settings. On a desktop the
# group is not greyed out, it is absent — an irrelevant control is clutter.
is_laptop() {
  if command -v omarchy-hw-laptop >/dev/null 2>&1; then omarchy-hw-laptop >/dev/null 2>&1; return; fi
  [[ -d /proc/acpi/button/lid ]]
}

# Writes key = value, creating the [section] and/or the key when either is
# absent — shell.toml ships nearly empty, so "the key isn't there yet" is the
# normal first write for most appearance settings, not an error.
# ── TOML / INI writing ──────────────────────────────────────────────────────
# Deliberately minimal: these target a flat "key = value" line inside a
# "[section]" of a small, hand-written config (shell.toml, a logind drop-in).
# They are not a TOML parser and are not meant to grow into one; anything more
# complex stays a whole-file MANIFEST entry, edited in a real editor.
# Reading goes through file_map() instead, which parses the whole file once.
toml_set() {
  invalidate_file_maps
  local file="$1" section="${2%%.*}" key="${2#*.}" value="$3" tmp
  [[ -f "$file" ]] || printf '' > "$file"
  tmp=$(mktemp)
  awk -v sect="[$section]" -v key="$key" -v val="$value" '
    BEGIN { done_it = 0; seen_sect = 0 }
    $0 ~ /^[[:space:]]*\[/ {
      if (in_sect && !done_it) { print key " = " val; done_it = 1 }
      in_sect = ($0 ~ "^[[:space:]]*\\" sect)
      if (in_sect) seen_sect = 1
      print; next
    }
    in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (done_it) next
      sub(/=[[:space:]]*.*/, "= " val); done_it = 1; print; next
    }
    { print }
    END {
      if (!done_it) {
        if (!seen_sect) { print ""; print sect }
        print key " = " val
      }
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# ── Hyprland Lua helpers ────────────────────────────────────────────────────
# Narrow on purpose. They match an uncommented "key = value" line and only act
# when that key appears EXACTLY ONCE in the file. A key that is absent, that
# only appears inside a `--` comment, or that appears in two different tables
# reads as missing, and the panel greys the control out.
#
# Refusing beats guessing here: these files decide whether the graphical session
# starts at all, and a generic nested-table editor would need a real Lua parser
# to be safe. Everything a single key can't express stays a whole-file entry in
# MANIFEST, edited in a real editor.
lua_key_hits() { grep -cE "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || true; }

lua_get() {
  local file="$1" key="$2" raw
  [[ -f "$file" ]] || return 1
  [[ "$(lua_key_hits "$file" "$key")" == "1" ]] || return 1
  raw=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -n1)
  raw=${raw#*=}
  printf '%s\n' "$raw" | sed -e 's/--.*$//' -e 's/[[:space:]]*$//' -e 's/,$//' \
                             -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                             -e 's/^"//' -e 's/"$//'
}

lua_set() {
  invalidate_file_maps
  local file="$1" key="$2" value="$3" tmp
  [[ -f "$file" ]] || return 1
  [[ "$(lua_key_hits "$file" "$key")" == "1" ]] || return 1
  tmp=$(mktemp)
  awk -v key="$key" -v val="$value" '
    !done_it && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0; comment = ""
      ci = index(line, "--")
      if (ci > 0) { comment = substr(line, ci); line = substr(line, 1, ci - 1) }
      match(line, /^[[:space:]]*/); indent = substr(line, 1, RLENGTH)
      comma = (line ~ /,[[:space:]]*$/) ? "," : ""
      out = indent key " = " val comma
      if (comment != "") out = out " " comment
      print out; done_it = 1; next
    }
    { print }
    END { if (!done_it) exit 3 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# lua_key_of <option> — the Lua key of a registry path: "input:touchpad:
# natural_scroll" is the line `natural_scroll = …` in the file.
lua_key_of() { printf '%s\n' "${1##*:}"; }

# hypr_in_force <option> — the value Hyprland is using now, as the file would
# spell it ("40", "true", "es"). Fails when there is no Hyprland to ask.
# `has()`, never `//`: jq's alternative operator treats false as missing, so a
# switch that is off would read as unknown.
hypr_in_force() {
  command -v hyprctl >/dev/null 2>&1 || return 1
  local out
  out=$(timeout 2 hyprctl getoption "$1" -j 2>/dev/null) || return 1
  jq -er 'if has("int") then .int elif has("float") then .float
          elif has("bool") then .bool elif has("str") then .str else empty end
          | tostring' <<<"$out" 2>/dev/null
}

# hypr_overrider <key> <own-file> — the tracked Hyprland file, other than the
# setting's own, with an uncommented `<key> =` line. Found modules are asked
# first: OmaSettings' omasettings.lua is loaded last, which is why it wins.
hypr_overrider() {
  local key="$1" own="$2" entry src
  for entry in ${AUTO_MANIFEST[@]+"${AUTO_MANIFEST[@]}"} "${TRACKED[@]}"; do
    src="${entry%%:*}"
    [[ "$src" == "$HOME/.config/hypr/"*.lua && "$src" != "$own" && -f "$src" ]] || continue
    [[ "$(lua_key_hits "$src" "$key")" -ge 1 ]] && { printf '%s\n' "${entry##*:}"; return 0; }
  done
  return 1
}

# ── read / write one setting ────────────────────────────────────────────────
setting_options() {
  # Two option lists are not fixed: the themes installed now, and the keyboard
  # layouts this machine knows (`@x11-layouts` in the registry). A fixed list
  # of eight layouts left anyone outside it with a control that could not show
  # or keep the value.
  local entry="$1" opts
  if [[ "$(setting_field "$entry" 5)" == "theme" ]]; then
    omarchy-theme-list 2>/dev/null | paste -sd, - || true
    return 0
  fi
  opts=$(setting_field "$entry" 10)
  if [[ "$opts" == "@x11-layouts" ]]; then
    opts=$(localectl list-x11-keymap-layouts 2>/dev/null | paste -sd, - || true)
    [[ -n "$opts" ]] || opts="us,es,gb,de,fr,it,pt,latam"
  fi
  printf '%s\n' "$opts"
}

get_setting_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file path type raw
  file=$(setting_field "$entry" 3); path=$(setting_field "$entry" 4); type=$(setting_field "$entry" 5)
  case "$type" in
    theme)
      omarchy-theme-current 2>/dev/null || return 1
      ;;
    line-enum)
      [[ -f "$file" ]] || return 1
      raw=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    toml-int|toml-float)
      [[ -f "$file" ]] || return 1
      raw=$(map_lookup "$file" toml "$path") || return 1
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    ini-enum)
      # No drop-in yet means logind is on its built-in default, which is what
      # the fallback field records — so report that rather than "missing".
      if [[ -f "$file" ]]; then
        raw=$(map_lookup "$file" toml "$path" 2>/dev/null || true)
        [[ -n "$raw" ]] && { printf '%s\n' "$raw"; return 0; }
      fi
      raw=$(setting_field "$entry" 13)
      [[ -n "$raw" ]] || return 1
      printf '%s\n' "$raw"
      ;;
    lua-int|lua-bool|lua-enum)
      map_lookup "$file" lua "$(lua_key_of "$path")"
      ;;
    *)
      [[ -f "$file" ]] || return 1
      # A missing key reads as absent, but `false` must not: jq's `//` fires on
      # false as well as null, so a boolean setting that is genuinely off would
      # look like a setting that is not there.
      raw=$(map_lookup "$file" json "$path") || return 1
      [[ "$raw" == "null" ]] && return 1
      printf '%s\n' "$raw"
      ;;
  esac
}

# numeric guard that also works for floats (bash arithmetic is integer-only)
num_in_range() {
  # Callers have already checked the shape of $1; this only bounds it, in awk
  # because bash arithmetic cannot compare floats.
  awk -v v="$1" -v lo="$2" -v hi="$3" '
    BEGIN {
      if (lo != "" && v + 0 < lo + 0) exit 1
      if (hi != "" && v + 0 > hi + 0) exit 1
      exit 0
    }' </dev/null
}

set_setting_value() {
  invalidate_file_maps
  local entry; entry=$(find_setting "$1") || { echo "unknown setting: $1" >&2; return 1; }
  local file path type label unit min max options apply value="$2"
  file=$(setting_field "$entry" 3);    path=$(setting_field "$entry" 4)
  type=$(setting_field "$entry" 5);    label=$(setting_field "$entry" 6)
  unit=$(setting_field "$entry" 7);    min=$(setting_field "$entry" 8)
  max=$(setting_field "$entry" 9);     apply=$(setting_field "$entry" 12)
  options=$(setting_options "$entry")

  # ── validate before touching anything
  case "$type" in
    number|toml-int|lua-int)
      [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "$1: '$value' is not a whole number" >&2; return 1; }
      num_in_range "$value" "$min" "$max" || { echo "$1: $value$unit is outside ${min:-?}–${max:-?}$unit" >&2; return 1; }
      ;;
    toml-float)
      [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { echo "$1: '$value' is not a number" >&2; return 1; }
      num_in_range "$value" "$min" "$max" || { echo "$1: $value$unit is outside ${min:-?}–${max:-?}$unit" >&2; return 1; }
      ;;
    bool|lua-bool)
      [[ "$value" == "true" || "$value" == "false" ]] || { echo "$1: '$value' must be true or false" >&2; return 1; }
      ;;
    enum|lua-enum|line-enum|theme|ini-enum)
      [[ -n "$options" ]] || { echo "$1: no options available on this machine" >&2; return 1; }
      [[ ",$options," == *",$value,"* ]] || { echo "$1: '$value' is not one of: ${options//,/, }" >&2; return 1; }
      ;;
  esac

  # ── write
  case "$type" in
    theme)
      omarchy-theme-set "$value" >/dev/null 2>&1 || { echo "$1: omarchy-theme-set failed" >&2; return 1; }
      ;;
    line-enum)
      backup_before_write "$file"
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$value" > "$file" || { echo "$1: could not write $file" >&2; return 1; }
      ;;
    toml-int|toml-float)
      backup_before_write "$file"
      toml_set "$file" "$path" "$value" || { echo "$1: could not write '$path' in $file — left untouched" >&2; return 1; }
      ;;
    ini-enum)
      # The reload is part of the privileged write, so root is asked once, not
      # twice — hence apply is consumed here and cleared before the tail below.
      ini_set "$file" "$path" "$value" "$apply" || { echo "$1: $file was left untouched" >&2; return 1; }
      apply=""
      ;;
    lua-int|lua-bool)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      lua_set "$file" "$(lua_key_of "$path")" "$value" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
      ;;
    lua-enum)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      lua_set "$file" "$(lua_key_of "$path")" "\"$value\"" || { echo "$1: '$path' is missing or ambiguous in $file — left untouched" >&2; return 1; }
      ;;
    number|bool)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      local tmp; tmp=$(mktemp)
      jq --argjson v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
    *)
      [[ -f "$file" ]] || { echo "file not found: $file" >&2; return 1; }
      backup_before_write "$file"
      local tmp; tmp=$(mktemp)
      jq --arg v "$value" "$path = \$v" "$file" > "$tmp" 2>/dev/null
      [[ -s "$tmp" ]] || { echo "$1: write failed, left $file untouched" >&2; rm -f "$tmp"; return 1; }
      mv "$tmp" "$file"
      ;;
  esac

  # ── make it take effect, when the target isn't watching its own file
  if [[ -n "$apply" ]]; then
    bash -c "$apply" >/dev/null 2>&1 || echo "$1: written, but '$apply' failed — it may need a manual reload" >&2
  fi
  echo "$label -> $value$unit" >&2
}

# ── humanising values ───────────────────────────────────────────────────────
# Omarchy stores idle timers in seconds and densities as bare multipliers.
# Those are the right things to store and the wrong things to *read*: "600"
# tells you nothing, "10 min" tells you everything. Every number the panel
# shows goes through here, and the CLI keeps speaking the stored unit.
human_duration() {
  local s="$1" h m
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '%s\n' "$s"; return; }
  (( s == 0 )) && { echo "never"; return; }
  (( s < 60 )) && { echo "${s} s"; return; }
  if (( s < 3600 )); then
    m=$(( s / 60 ))
    if (( s % 60 == 0 )); then echo "${m} min"; else echo "${m} min $(( s % 60 )) s"; fi
    return
  fi
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if (( m == 0 )); then echo "${h} h"; else echo "${h} h ${m} min"; fi
}

# "1" and "1.0" are the same density; printing them differently made the panel
# offer a "back to the Omarchy default" button that would have changed nothing.
canon_number() {
  local v="$1"
  [[ "$v" == *.* ]] || { printf '%s\n' "$v"; return; }
  v="${v%"${v##*[!0]}"}"   # drop trailing zeros
  v="${v%.}"               # and a bare trailing dot
  printf '%s\n' "${v:-0}"
}

# human_value <type> <unit> <scale> <display_unit> <raw>
human_value() {
  local type="$1" unit="$2" scale="$3" disp="$4" raw="$5"
  [[ -n "$raw" ]] || { echo "—"; return; }
  case "$type" in
    bool|lua-bool) [[ "$raw" == "true" ]] && echo "on" || echo "off"; return ;;
    toml-float)    raw=$(canon_number "$raw") ;;
  esac
  if [[ "$scale" == "60" ]]; then human_duration "$raw"; return; fi
  case "$unit" in
    "")  printf '%s\n' "$raw" ;;
    "×") printf '%s×\n' "$raw" ;;
    "/s") printf '%s/s\n' "$raw" ;;
    *)   printf '%s %s\n' "$raw" "${disp:-$unit}" ;;
  esac
}

# read_setting_from <entry> <file> — the same getter as get_setting_value, but
# pointed at any file. Used to read the key out of Omarchy's shipped default
# and out of the repo's saved copy, which is what makes the two revert buttons
# possible without a second parser.
# ─── One pass per file, not one process per value ───────────────────────────
# Every setting is read three times — the live file, Omarchy's default, and the
# copy in the repo — and each read forked at least one process. lua_get forked
# FOUR (two greps, a head and a sed). Twenty-four settings came to something
# like seventy processes per panel refresh, which was two thirds of the time
# `status --json` took.
#
# Each file is now parsed once, whole, into "path<TAB>value" lines, and the
# per-setting reads are lookups in a string. Parsing the whole file costs the
# same as parsing one key out of it: the process was the expense, not the work.
declare -gA FILE_MAP_CACHE=()
declare -gA FILE_MAP_LOADED=()
invalidate_file_maps() { FILE_MAP_CACHE=(); FILE_MAP_LOADED=(); }

# Command substitution forks, and a fork copies the caches rather than sharing
# them: a map built inside `$(file_map ...)` dies with the subshell, so the
# first version of this parsed every file on every single lookup and saved
# almost nothing. The parse therefore has to happen in the PARENT — warm_*
# below does that once, and the subshells then inherit a populated map.
#
# load_file_map is the half that may be called in the parent: it prints nothing.
load_file_map() {
  local file="$1" kind="$2" key="$1|$2"
  if [[ -z "${FILE_MAP_LOADED[$key]:-}" ]]; then
    FILE_MAP_LOADED[$key]=1
    FILE_MAP_CACHE[$key]=""
    if [[ -f "$file" ]]; then
      case "$kind" in
        json)
          # ".idle.lock<TAB>600" — the same dotted form field 4 uses.
          #
          # NOT paths(scalars): jq's path filter selects on truthiness, so a key
          # whose value is `false` produces no path and vanishes from the map.
          # A boolean setting that is genuinely off would then read as missing,
          # which is the exact bug the comment in get_setting_value warns about.
          FILE_MAP_CACHE[$key]=$(jq -r '
            paths as $p | getpath($p) as $v
            | select(($v|type) != "object" and ($v|type) != "array")
            | "." + ($p|map(tostring)|join(".")) + "\t" + ($v|tostring)
          ' "$file" 2>/dev/null || true) ;;
        toml)
          # The key charset is deliberately "anything that is not whitespace or
          # an equals sign", because that is what the greps this replaces
          # matched. shell.toml's key is `base-size`: an identifier pattern
          # dropped it, and the setting read as missing.
          FILE_MAP_CACHE[$key]=$(awk '
            /^[[:space:]]*\[/ { sect = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sect); next }
            /^[[:space:]]*[^#=[:space:]]+[[:space:]]*=/ {
              k = $0; sub(/[[:space:]]*=.*$/, "", k); gsub(/^[[:space:]]+/, "", k)
              v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v)
              print (sect == "" ? k : sect "." k) "\t" v
            }' "$file" 2>/dev/null || true) ;;
        lua)
          # lua_get deliberately refuses a key that appears twice — a nested
          # table needs a real parser and these files decide whether the
          # graphical session starts. The map keeps that: a key seen more than
          # once is dropped rather than guessed at.
          FILE_MAP_CACHE[$key]=$(awk '
            /^[[:space:]]*[^#=[:space:]]+[[:space:]]*=/ {
              k = $0; sub(/[[:space:]]*=.*$/, "", k); gsub(/^[[:space:]]+/, "", k)
              v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
              sub(/--.*$/, "", v); sub(/,[[:space:]]*$/, "", v)
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
              gsub(/^"|"$/, "", v)
              n[k]++; val[k] = v
            }
            END { for (k in n) if (n[k] == 1) print k "\t" val[k] }' "$file" 2>/dev/null || true) ;;
      esac
    fi
  fi
}

# file_map <file> <json|toml|lua> — every scalar in the file, keyed the way the
# SETTINGS registry addresses it.
file_map() {
  load_file_map "$1" "$2"
  printf '%s' "${FILE_MAP_CACHE[$1|$2]}"
}

# Parse, in this shell, every file the registry will be read from: the live one,
# Omarchy's default and the copy in the repo. Fourteen files instead of seventy
# lookups, and every lookup after this is a string search.
map_kind_for_type() {
  case "$1" in
    toml-int|toml-float|ini-enum)  echo toml ;;
    lua-int|lua-bool|lua-enum)     echo lua ;;
    number|bool|enum)              echo json ;;
    *)                             echo "" ;;
  esac
}
warm_setting_file_maps() {
  local entry file type kind def rel copy
  for entry in "${SETTINGS[@]}"; do
    file=$(setting_field "$entry" 3); type=$(setting_field "$entry" 5)
    [[ "$file" != "-" ]] || continue
    kind=$(map_kind_for_type "$type"); [[ -n "$kind" ]] || continue
    load_file_map "$file" "$kind"
    def=$(default_for_src "$file" 2>/dev/null || true)
    [[ -n "$def" ]] && load_file_map "$def" "$kind"
    rel=$(rel_for_src "$file" 2>/dev/null || true)
    [[ -n "$rel" ]] && { copy=$(repo_copy_for_rel "$rel"); load_file_map "$copy" "$kind"; }
  done
}

# map_lookup <file> <kind> <key> — the value, or failure when the key is absent.
#
# The obvious spelling, map_get "$(file_map ...)" "$key", is TWO command
# substitutions and therefore two forks per read, three reads per setting,
# twenty-four settings. This is one.
map_lookup() {
  load_file_map "$1" "$2"
  local k v
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$3" ]] && { printf '%s\n' "$v"; return 0; }
  done <<<"${FILE_MAP_CACHE[$1|$2]}"
  return 1
}

read_setting_from() {
  local entry="$1" file="$2" path type raw
  path=$(setting_field "$entry" 4); type=$(setting_field "$entry" 5)
  [[ -f "$file" ]] || return 1
  case "$type" in
    line-enum)
      raw=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    toml-int|toml-float|ini-enum)
      raw=$(map_lookup "$file" toml "$path") || return 1
      [[ -n "$raw" ]] && printf '%s\n' "$raw" || return 1 ;;
    lua-int|lua-bool|lua-enum)
      map_lookup "$file" lua "$(lua_key_of "$path")" ;;
    number|bool|enum)
      raw=$(map_lookup "$file" json "$path") || return 1
      [[ "$raw" == "null" ]] && return 1
      printf '%s\n' "$raw" ;;
    *) return 1 ;;
  esac
}

# The value this setting would have on a machine that had never been touched.
# Read out of the file Omarchy actually ships where there is one; otherwise the
# registry's `fallback`, which is the shell's own built-in default.
setting_default_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file def
  file=$(setting_field "$entry" 3)
  if [[ "$file" != "-" ]] && def=$(default_for_src "$file" 2>/dev/null) && [[ -n "$def" ]]; then
    read_setting_from "$entry" "$def" && return 0
  fi
  def=$(setting_field "$entry" 13)
  [[ -n "$def" ]] && { printf '%s\n' "$def"; return 0; }
  return 1
}

# The value saved in the user's own repo — "what my other machine has".
setting_repo_value() {
  local entry; entry=$(find_setting "$1") || return 1
  local file rel copy
  file=$(setting_field "$entry" 3)
  [[ "$file" != "-" ]] || return 1
  rel=$(rel_for_src "$file") || return 1
  copy=$(repo_copy_for_rel "$rel")
  read_setting_from "$entry" "$copy"
}

# core_revert <id> <default|repo> — put one setting back without touching the
# rest of the file it lives in. The whole-file equivalents (`reset`, `restore`)
# are still there; this is the small, everyday one.
core_revert() {
  local id="$1" to="${2:-default}" value
  # Say which of the two things is wrong. Both failures below assume the id is
  # real, so an id that is not reported "no Omarchy default known for
  # nope.setting" — which reads as a fact about a setting that does not exist.
  find_setting "$id" >/dev/null || { echo "unknown setting: $id" >&2; return 1; }
  case "$to" in
    default) value=$(setting_default_value "$id") || { echo "no Omarchy default known for $id" >&2; return 1; } ;;
    repo)    value=$(setting_repo_value "$id")    || { echo "$id is not saved in your repo yet" >&2; return 1; } ;;
    *)       echo "revert: --to must be 'default' or 'repo'" >&2; return 1 ;;
  esac
  set_setting_value "$id" "$value"
}

# Numbers the panel can show without the user doing arithmetic. `value` stays
# the stored value (what the CLI reads and writes); `display_*` is the same
# quantity in the unit a person thinks in, and `value_text` is the exact
# current value written out in full, which is what the Overview table shows.
settings_display_step() {
  local scale="$1" dmax="$2" unit="$3"
  if [[ "$scale" != "1" && -n "$scale" ]]; then
    if [[ -n "$dmax" ]] && (( dmax > 60 )); then echo 5; else echo 1; fi
  elif [[ "$unit" == "ms" ]]; then echo 50
  else echo 1
  fi
}

build_settings_json() {
  invalidate_file_maps
  warm_setting_file_maps
  # One jq invocation for the whole array, not one per setting. The panel polls
  # status once a minute and refreshes after every write, and twenty-odd `jq -n`
  # spawns per build were most of the time that took.
  local entry id group file path type label unit min max options hint value available fallback implicit
  local scale disp dvalue dmin dmax dstep vtext defval deftext repoval repotext canrd canrr numeric boolean
  local lnotice inforce by
  {
  local laptop=1; is_laptop || laptop=0
  local -a F
  for entry in "${SETTINGS[@]}"; do
    # Split the line ONCE. Each setting_field call is a command substitution,
    # which is a fork, and thirteen of them per setting across twenty-four
    # settings was three hundred forks to read a string this shell already had.
    IFS='|' read -ra F <<<"$entry"
    id="${F[0]}";        group="${F[1]}"
    # A desktop has no lid. The group is absent rather than greyed out.
    [[ "$group" == "Lid & sleep" && "$laptop" == 0 ]] && continue
    file="${F[2]}";      path="${F[3]}"
    type="${F[4]}";      label="${F[5]}"
    unit="${F[6]}";      min="${F[7]}"
    max="${F[8]}";       hint="${F[10]}"
    fallback="${F[12]:-}"
    scale="${F[13]:-}";  disp="${F[14]:-}"
    [[ -n "$scale" ]] || scale=1
    [[ -n "$disp" ]] || disp="$unit"
    options=$(setting_options "$entry")
    value=$(get_setting_value "$id" 2>/dev/null) || value=""
    implicit=false
    if [[ -z "$value" && -n "$fallback" ]]; then value="$fallback"; implicit=true; fi
    if [[ -n "$value" ]]; then available=true; else available=false; fi

    # Shape check per type — a malformed value is "not available", never a
    # control bound to a value it cannot render.
    numeric=false; boolean=false
    case "$type" in
      number|toml-int|lua-int)
        numeric=true; [[ "$value" =~ ^-?[0-9]+$ ]] || { value=""; available=false; } ;;
      toml-float)
        numeric=true; [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { value=""; available=false; } ;;
      bool|lua-bool)
        boolean=true; [[ "$value" == "true" || "$value" == "false" ]] || { value="false"; available=false; } ;;
    esac

    dvalue=""; dmin=""; dmax=""; dstep=1
    if [[ "$numeric" == true ]]; then
      if [[ "$scale" == "1" ]]; then
        dvalue="$value"; dmin="$min"; dmax="$max"
      else
        [[ -n "$value" ]] && dvalue=$(( (value + scale / 2) / scale ))
        [[ -n "$min" ]] && dmin=$(( (min + scale - 1) / scale ))
        [[ -n "$max" ]] && dmax=$(( max / scale ))
      fi
      dstep=$(settings_display_step "$scale" "$dmax" "$unit")
    fi

    vtext=$(human_value "$type" "$unit" "$scale" "$disp" "$value")
    defval=$(setting_default_value "$id" 2>/dev/null) || defval=""
    repoval=$(setting_repo_value "$id" 2>/dev/null) || repoval=""
    deftext=$(human_value "$type" "$unit" "$scale" "$disp" "$defval")
    repotext=$(human_value "$type" "$unit" "$scale" "$disp" "$repoval")
    # Compare the rendered text, not the raw string: shell.toml holding "1" and
    # a fallback of "1.0" are the same density, and offering a revert button
    # that would change nothing is worse than offering none.
    canrd=false; canrr=false
    [[ -n "$defval"  && "$deftext"  != "$vtext" && "$available" == true ]] && canrd=true
    [[ -n "$repoval" && "$repotext" != "$vtext" && "$available" == true ]] && canrr=true

    # Hyprland is asked, not the file. These controls write input.lua, and a
    # module loaded after it that sets the same key wins: OmaSettings keeps
    # its Keyboard and Mouse pages in hypr/omasettings.lua, loaded last. The
    # row then showed what the file says while the session did something else.
    # Said only when Hyprland answers, and only when the two differ.
    lnotice=""
    if [[ "$type" == lua-* && "$available" == true ]] && inforce=$(hypr_in_force "$path"); then
      if [[ "$type" == lua-bool ]]; then
        [[ "$inforce" == 1 ]] && inforce=true
        [[ "$inforce" == 0 ]] && inforce=false
      fi
      if [[ "$inforce" != "$value" ]]; then
        by=$(hypr_overrider "$(lua_key_of "$path")" "$file") || by="a file loaded later"
        lnotice="In force: $(human_value "$type" "$unit" "$scale" "$disp" "$inforce") — set by $by."
      fi
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$id" "$group" "$label" "$type" "$unit" "$min" "$max" "$options" "$hint" "$file" \
      "$available" "$implicit" "$value" "$scale" "$disp" "$dvalue" "$dmin" "$dmax" "$dstep" \
      "$vtext" "$defval" "$deftext" "$repoval" "$repotext" "$canrd" "$canrr" "$numeric" "$boolean" \
      "$lnotice"
  done
  } | jq -Rsc '
    def num: if . == "" then null else (tonumber? // null) end;
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], group: .[1], label: .[2], type: .[3], unit: .[4],
      min: (.[5]|num), max: (.[6]|num),
      options: (if .[7] == "" then [] else (.[7]|split(",")) end),
      hint: .[8], file: .[9],
      available: (.[10]|flag), implicit: (.[11]|flag),
      value: (if (.[27]|flag) then (.[12] == "true")
              elif (.[26]|flag) then (.[12]|num)
              else .[12] end),
      scale: (.[13]|num), display_unit: .[14],
      display_value: (.[15]|num), display_min: (.[16]|num),
      display_max: (.[17]|num), display_step: ((.[18]|num) // 1),
      value_text: .[19],
      default_value: .[20], default_text: .[21],
      repo_value: .[22], repo_text: .[23],
      can_revert_default: (.[24]|flag), can_revert_repo: (.[25]|flag),
      lua_notice: (.[28] // "")
    })' | jq -c --arg lidblock "$(lid_blocked_by)" '
    # A second pass, because a notice is about how settings sit RELATIVE to each
    # other and the per-setting record cannot see its siblings.
    #
    # Exactly one rule, on purpose. A screensaver set at or after the lock timer
    # can never appear — the setting silently does nothing, which is worth
    # saying. The other orderings people assume are wrong are not: a display that
    # sleeps long before the lock is a normal power choice, and suspending before
    # the lock timer is fine because Omarchy locks on suspend. Warning about
    # those fires on a perfectly good config and teaches people to ignore
    # notices, which costs more than it saves.
    #
    # A notice, never a refusal. A deliberate 0 ("never") is a real answer.
    def val($id): [ .[] | select(.id == $id) | .value ][0];
    (val("idle.screensaver")) as $ss
    | (val("idle.lock")) as $lock
    | map(. + { notice: (
        if .id == "idle.screensaver" and ($ss != null and $lock != null and $lock > 0 and $ss >= $lock)
          then "The screen locks first, so this screensaver never appears."
        # Not a warning about how you configured it — a statement that what you
        # configured is not what happens. Something else is holding the lid
        # switch and logind is ignoring this file.
        elif (.id | startswith("lid.")) and $lidblock != ""
          # Two lines of about 34 characters is what the row gives it, so the
          # sentence has to fit in ~66 — the first attempt said the same thing
          # in 91 and lost "does nothing" to the ellipsis, which was the half
          # worth reading.
          then "Overridden by \($lidblock) — the lid does nothing."
        # The same statement about Hyprland: what the session uses is not what
        # the file says (see lnotice above).
        elif .lua_notice != "" then .lua_notice
        else "" end) } | del(.lua_notice))'
}

# lid_blocked_by — who, if anyone, is holding a `block` inhibitor on the lid
# switch. Empty when nobody is.
#
# This exists because the panel was telling a confident lie. It reported
# lid.close by reading /etc/systemd/logind.conf.d/99-lid.conf — the file it
# writes itself — while a plugin (Omarchy Sleepwalker) held a block inhibitor
# that makes logind ignore the lid entirely. The config said
# "suspend-then-hibernate"; closing the lid did nothing at all.
#
# Same shape as the bug that opened this whole line of work: answering a
# question about the SYSTEM by reading the ARTIFACT you wrote. A `delay`
# inhibitor is not this — those are normal and transient (NetworkManager and
# UPower each hold one). Only `block` overrides the setting.
lid_blocked_by() {
  # WHO is free text and often contains spaces ("Omarchy Sleepwalker"), so it
  # is neither $1 nor a greedy regex — both got it wrong. Between WHO and WHAT
  # there are exactly four columns (UID USER PID COMM), so WHO is everything
  # up to five fields before the one reading handle-lid-switch.
  # An inhibitor may hold SEVERAL whats at once, and systemd prints them
  # colon-joined in one column: `sleep:idle:handle-lid-switch`. Testing the
  # field for equality missed every one of those — it only ever matched a holder
  # that wanted the lid and nothing else.
  systemd-inhibit --list --no-pager 2>/dev/null | awk '
    $NF == "block" {
      for (i = 1; i <= NF; i++) if ($i ~ /(^|:)handle-lid-switch(:|$)/) {
        who = ""
        for (j = 1; j <= i - 5; j++) who = who (j > 1 ? " " : "") $j
        if (who != "") { print who; exit }
      }
    }'
}

build_setting_groups_json() {
  local entries=() entry
  local laptop=1; is_laptop || laptop=0
  for entry in "${SETTING_GROUPS[@]}"; do
    [[ "${entry%%|*}" == "Lid & sleep" && "$laptop" == 0 ]] && continue
    entries+=("$(jq -nc --arg name "$(printf '%s' "$entry" | cut -d'|' -f1)" \
      --arg icon "$(printf '%s' "$entry" | cut -d'|' -f2)" \
      --arg description "$(printf '%s' "$entry" | cut -d'|' -f3)" \
      '{name:$name,icon:$icon,description:$description}')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
}
