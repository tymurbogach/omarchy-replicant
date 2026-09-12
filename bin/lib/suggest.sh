# shellcheck shell=bash disable=SC2034
# suggest.sh: proposing files that nothing tracks yet.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── suggest — the part that makes adding easy ──────────────────────────────
# The manifest is deliberately not auto-discovery: the guarantee that only what
# a human decided to track gets tracked is the point of the whole thing. But
# "you may add anything you like" is worthless if finding it means remembering
# every path you ever edited. So this proposes, and the user disposes: it walks
# the few places hand-written config actually lives and prints what is not
# tracked yet, with the reason it is worth a second look.
#
# Everything it refuses to suggest, it refuses for a mechanical reason, never
# a guess about taste:
SUGGEST_MAX_BYTES=262144   # a config file people wrote by hand; not a database

# What a config file looks like. A positive list rather than a blocklist,
# because the things under ~/.config that are NOT config outnumber the things
# that are, and they are invented faster than anyone can exclude them.
SUGGEST_EXTENSIONS="conf toml ini yml yaml lua json jsonc rc list css scss sh bash fish zsh service timer socket desktop kdl nix editorconfig theme vim tpl"

# An Electron or Chromium application keeps its entire state in ~/.config/<app>,
# and every file in there is machine-generated: "Local State", "Preferences",
# "TransportSecurity", a machine id. Suggesting them would bury the handful of
# files a person actually wrote, and restoring one onto another machine would
# be actively wrong. The tell is reliable and cheap — these names are the
# Chromium profile layout, and nothing hand-written is called any of them.
APP_STATE_MARKERS=("Local State" "Preferences" "TransportSecurity" "machineid" "Cookies" "History" "Network Persistent State" "Session Storage" "blob_storage" "Service Worker")

is_app_state_dir() {
  local d="$1" m
  for m in "${APP_STATE_MARKERS[@]}"; do [[ -e "$d/$m" ]] && return 0; done
  return 1
}

suggest_skip_reason() {
  # TWO `local` statements, and that is not style. Bash expands every word on a
  # `local` line BEFORE performing any of its assignments, so in
  # `local f="$1" base="${f##*/}"` the `$f` that `base` reads is NOT the one
  # being assigned on the same line — it is whatever `f` meant in the caller.
  #
  # This worked, and only by accident: bash scopes dynamically, the sole caller
  # is core_suggest, and core_suggest's loop variable is also called `f` and
  # holds the same path. Rename it there and every test in this function goes
  # quietly dead — symlinks, .bak files, oversized files, binaries, application
  # state, package-manager files, runtime state, mise shims, plugin-installed
  # scripts and files identical to Omarchy's default would all start being
  # offered, which is the opposite of what the README promises, with no error
  # anywhere. Called on its own under `set -u` it aborts outright on this line.
  #
  # Found by shellcheck (SC2318/SC2178) the first time it was ever installed.
  local f="$1"
  local base="${f##*/}" ext="${f##*.}"
  [[ -L "$f" ]]                             && { echo "a symlink"; return 0; }
  [[ "$base" == *.bak.* || "$base" == *~ ]] && { echo "a backup"; return 0; }
  [[ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt $SUGGEST_MAX_BYTES ]] && { echo "too big to be hand-written"; return 0; }
  grep -Iq . "$f" 2>/dev/null || { echo "not a text file"; return 0; }
  is_app_state_dir "$(dirname "$f")" && { echo "an application's own state"; return 0; }
  case "$base" in
    package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|composer.lock)
      { echo "a package manager's file"; return 0; } ;;
    *session*|*state*|*.log|*.pid|*.sock*|*.db|*.lock)
      { echo "runtime state, not config"; return 0; } ;;
  esac
  # A script has no extension to go by, so it is judged by living where you put
  # scripts: ~/.local/bin, or an Omarchy hook directory. Everything else must
  # look like config.
  if [[ "$f" != "$HOME/.local/bin/"* && "$f" != "$HOME/.config/omarchy/hooks/"* ]]; then
    [[ "$ext" != "$base" ]] || { echo "no extension — not obviously config"; return 0; }
    [[ " $SUGGEST_EXTENSIONS " == *" ${ext,,} "* ]] || { echo ".$ext is not a config format"; return 0; }
  fi
  # A mise shim is generated, identical on every machine, and recreated by
  # `mise use -g` — nine of them in ~/.local/bin would drown the real scripts.
  grep -qE '^exec mise x ' "$f" 2>/dev/null && { echo "a mise shim"; return 0; }
  # Installed by another plugin, which is what reinstalls it. The tell is the
  # uninstaller every Omarchy plugin installer drops beside its script.
  [[ -e "${f}-uninstall" ]] && { echo "installed by a plugin"; return 0; }
  [[ "$base" == *-uninstall ]] && [[ -e "${f%-uninstall}" ]] && { echo "installed by a plugin"; return 0; }
  # Byte-identical to what Omarchy ships: nothing of yours is in it, and
  # `omarchy refresh config` already puts it back.
  is_default_file "$f" 2>/dev/null && { echo "identical to Omarchy's default"; return 0; }
  return 1
}

# Some config files hold a credential. gh/hosts.yml carries an OAuth token, a
# .netrc carries a password. They are perfectly reasonable things to back up
# into a private repo — but as secrets, at mode 600, with their contents never
# rendered in the panel. Suggesting one as ordinary config is how a token ends
# up world-readable in a git checkout, so it is named here.
suggest_kind() {
  case "${1##*/}" in
    hosts.yml|hosts.yaml|.netrc|netrc|credentials|credentials.*|*token*|*secret*|*.pem|*.key)
      echo secret ;;
    *) echo config ;;
  esac
}

# core_suggest [--json] — "path<TAB>rel<TAB>reason" per line, or the same as
# JSON for the panel's checklist.
core_suggest() {
  local as_json=0; [[ "${1:-}" == "--json" ]] && as_json=1
  {
    local f reason kind
    # Top level of ~/.config and one directory down: deep trees are libraries
    # and caches, and the config people actually edit is never four levels in.
    while IFS= read -r f; do
      is_tracked_path "$f" && continue
      case "$f" in
        */omarchy/themes/*|*/omarchy/backgrounds/*) continue ;;  # inventoried, not copied
        */.git/*|*/node_modules/*|*/cache/*|*/Cache/*) continue ;;
      esac
      suggest_skip_reason "$f" >/dev/null && continue
      reason="config you edited by hand"
      case "$f" in
        */systemd/user/*) reason="a user service you added" ;;
        "$HOME/.local/bin/"*) reason="a script you wrote" ;;
        */omarchy/hooks/*) reason="an Omarchy hook you added" ;;
        */omarchy/themed/*) reason="a theme template you changed" ;;
      esac
      kind=$(suggest_kind "$f")
      [[ "$kind" == secret ]] && reason="holds a credential — track it as a secret"
      printf '%s\t%s\t%s\t%s\n' "$f" "$(derive_rel "$f")" "$reason" "$kind"
    done < <({
      find "$HOME/.config" -maxdepth 2 -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -type f -executable 2>/dev/null
      # Omarchy's two extension points, both deeper than the scan above. It
      # ships a .sample in each, which is Omarchy's file and not the user's.
      find "$HOME/.config/omarchy/hooks" -mindepth 2 -maxdepth 2 -type f ! -name '*.sample' 2>/dev/null
      find "$HOME/.config/omarchy/themed" -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null
    } | sort -u)
  # Credentials first — "secret" sorts after "config", hence -r — and stably,
  # so everything else keeps path order. The list is long and, in the panel,
  # lives at the bottom of a longer one: a row buried at position fourteen is a
  # row nobody reads, and this is the one whose cost of being missed is an OAuth
  # token sitting world-readable in a git checkout.
  } | sort -s -t$'\t' -k4,4r | if (( as_json )); then
    jq -Rsc 'def home: sub("^"+$ENV.HOME; "~");
      split("\n") | map(select(length > 0) | split("\t")
      | {path: .[0], pretty: (.[0]|home), id: .[1], reason: .[2], kind: .[3]})'
  else
    cat
  fi
}
