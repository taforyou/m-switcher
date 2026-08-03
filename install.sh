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

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.claude"

install -m 755 "$here/m" "$HOME/.local/bin/m"

if [ -f "$HOME/.claude/providers.json" ]; then
  echo "kept existing ~/.claude/providers.json"
else
  cp "$here/providers.example.json" "$HOME/.claude/providers.json"
  echo "created ~/.claude/providers.json from the example"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH (e.g. in ~/.zshrc):"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo
echo "installed. next steps:"
echo "  1. put your API keys in ~/.claude/providers.json (keys still wrapped in <> are refused)"
echo "  2. run: m"
