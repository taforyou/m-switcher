#!/bin/sh
# Installs the `m` provider switcher for Claude Code.
set -e

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required. install it first (macOS: brew install jq)" >&2
  exit 1
}
command -v zsh >/dev/null 2>&1 || {
  echo "error: zsh is required (default shell on macOS; 'apt install zsh' on Linux)" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "error: curl is required for providers with live model catalogs" >&2
  exit 1
}

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.claude"
# Everything created below holds or may hold API keys: make it private.
umask 077

install -m 755 "$here/m" "$HOME/.local/bin/m"

# Follow a symlinked providers.json (dotfiles setups) so it is updated in
# place instead of being replaced by a regular file.
prov="$HOME/.claude/providers.json"
while [ -L "$prov" ]; do
  link="$(readlink "$prov")"
  case "$link" in
    /*) prov="$link" ;;
    *)  prov="$(dirname "$prov")/$link" ;;
  esac
done

if [ -f "$prov" ]; then
  if jq -e --slurpfile defaults "$here/providers.example.json" \
       '($defaults[0] * .) == .' "$prov" >/dev/null; then
    echo "kept existing ~/.claude/providers.json"
  else
    tmp="$(mktemp "$prov.XXXXXX")"
    # Defaults fill missing providers and nested fields; existing user values
    # win at every level.
    jq -s '.[1] * .[0]' "$prov" "$here/providers.example.json" > "$tmp"
    cp "$prov" "$prov.bak"
    chmod 600 "$prov.bak"
    chmod 600 "$tmp"
    mv "$tmp" "$prov"
    echo "added new bundled provider fields to ~/.claude/providers.json (existing values preserved)"
  fi
else
  cp "$here/providers.example.json" "$prov"
  chmod 600 "$prov"
  echo "created ~/.claude/providers.json from the example"
fi
chmod 600 "$prov"

# Backups written by earlier versions inherited a permissive mode while
# holding live keys; make any that exist private too.
for f in "$prov.bak" "$HOME/.claude/settings.json.bak"; do
  if [ -f "$f" ]; then
    chmod 600 "$f"
  fi
done

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH (e.g. in ~/.zshrc):"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo
echo "installed. next steps:"
echo "  1. run 'm key openrouter' (or put provider keys in ~/.claude/providers.json)"
echo "  2. run: m"
