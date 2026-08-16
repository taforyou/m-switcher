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

install -m 755 "$here/m" "$HOME/.local/bin/m"

if [ -f "$HOME/.claude/providers.json" ]; then
  if jq -e --slurpfile defaults "$here/providers.example.json" \
       '($defaults[0] * .) == .' "$HOME/.claude/providers.json" >/dev/null; then
    echo "kept existing ~/.claude/providers.json"
  else
    tmp="$(mktemp "$HOME/.claude/providers.json.XXXXXX")"
    # Defaults fill missing providers and nested fields; existing user values
    # win at every level.
    jq -s '.[1] * .[0]' \
      "$HOME/.claude/providers.json" "$here/providers.example.json" > "$tmp"
    cp "$HOME/.claude/providers.json" "$HOME/.claude/providers.json.bak"
    chmod 600 "$tmp"
    mv "$tmp" "$HOME/.claude/providers.json"
    echo "added new bundled provider fields to ~/.claude/providers.json (existing values preserved)"
  fi
else
  cp "$here/providers.example.json" "$HOME/.claude/providers.json"
  chmod 600 "$HOME/.claude/providers.json"
  echo "created ~/.claude/providers.json from the example"
fi
chmod 600 "$HOME/.claude/providers.json"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH (e.g. in ~/.zshrc):"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo
echo "installed. next steps:"
echo "  1. run 'm key openrouter' (or put provider keys in ~/.claude/providers.json)"
echo "  2. run: m"
