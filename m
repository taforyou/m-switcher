#!/bin/zsh
# m — switch Claude Code between providers in ~/.claude/settings.json
#   m              -> interactive picker (up/down arrows, return to switch, q to quit)
#   m claude       -> back to Anthropic default (removes provider env)
#   m zai | kimi   -> switch to that provider (names come from ~/.claude/providers.json)
#   m status       -> print the active provider
# Providers live in ~/.claude/providers.json: { "<name>": { "label": "...", "env": {...} } }
# M_SETTINGS=<file> overrides the settings path (for testing).

set -e
SETTINGS="${M_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="${M_CLAUDE_JSON:-$HOME/.claude.json}"
PROV="$HOME/.claude/providers.json"

[[ -f "$SETTINGS" ]] || { echo "missing $SETTINGS" >&2; exit 1; }
[[ -f "$PROV"     ]] || { echo "missing $PROV" >&2; exit 1; }

names=(claude ${(f)"$(jq -r 'keys_unsorted[]' "$PROV")"})

label_of() {
  if [[ "$1" == claude ]]; then
    echo "claude (anthropic default)"
  else
    jq -r --arg n "$1" '.[$n].label // $n' "$PROV"
  fi
}

current() {
  jq -r --slurpfile p "$PROV" '
    (.env.ANTHROPIC_BASE_URL // "") as $b
    | first($p[0] | to_entries[] | select(.value.env.ANTHROPIC_BASE_URL == $b) | .key) // "claude"
  ' "$SETTINGS"
}

switch_to() {
  local name="$1"
  if [[ "$name" != claude ]]; then
    local token
    token="$(jq -r --arg n "$name" '.[$n].env | (.ANTHROPIC_AUTH_TOKEN // .ANTHROPIC_API_KEY // "")' "$PROV")"
    if [[ -z "$token" || "$token" == \<* ]]; then
      echo "refusing: API key for '$name' is not set in $PROV" >&2
      echo "edit it first:  \${EDITOR:-nano} $PROV" >&2
      return 3
    fi
  fi
  local tmp
  tmp="$(mktemp "$SETTINGS.XXXXXX")"
  if ! jq --slurpfile p "$PROV" --arg name "$name" '
       ($p[0] | [.[].env | keys[]] | unique) as $all
       | .env = ((.env // {}) | with_entries(.key as $k | select(($all | index($k)) | not)))
       | (if $name != "claude" then .env += $p[0][$name].env else . end)
       | if .env == {} then del(.env) else . end
     ' "$SETTINGS" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  cp "$SETTINGS" "$SETTINGS.bak"
  mv "$tmp" "$SETTINGS"
  # provider-declared ~/.claude.json flags (e.g. kimi needs penguinModeOrgEnabled)
  local cj
  cj="$(jq -c --arg n "$name" 'if $n == "claude" then {} else .[$n].claudeJson // {} end' "$PROV")"
  if [[ "$cj" != "{}" ]]; then
    local tmp2
    tmp2="$(mktemp "${CLAUDE_JSON}.XXXXXX")"
    if [[ -f "$CLAUDE_JSON" ]]; then
      jq --argjson add "$cj" '. + $add' "$CLAUDE_JSON" > "$tmp2"
    else
      printf '%s\n' "$cj" > "$tmp2"
    fi
    mv "$tmp2" "$CLAUDE_JSON"
  fi
  echo "switched to $(label_of "$name") — restart claude to take effect"
}

picker() {
  local cur sel i n=${#names}
  cur="$(current)"
  sel=1
  for i in {1..$n}; do [[ "${names[i]}" == "$cur" ]] && sel=$i; done
  printf '\e[?25l'
  {
    local first=1 key rest
    while true; do
      (( first )) || printf '\e[%dA' $(( n + 1 ))
      first=0
      for i in {1..$n}; do
        local mark=" "
        [[ "${names[i]}" == "$cur" ]] && mark="o"
        if (( i == sel )); then
          printf '\e[K  \e[36m%s %s\e[0m\n' "$mark" "$(label_of "${names[i]}")"
        else
          printf '\e[K  %s %s\n' "$mark" "$(label_of "${names[i]}")"
        fi
      done
      printf '\e[K\e[2mup/down to select, return to switch, q to quit\e[0m\n'
      read -sk1 key || { key="q" }
      case "$key" in
        $'\e')
          rest=""
          read -sk2 -t 0.05 rest 2>/dev/null || true
          case "$rest" in
            '[A') (( sel > 1 )) && (( sel-- )) || true ;;
            '[B') (( sel < n )) && (( sel++ )) || true ;;
          esac ;;
        k) (( sel > 1 )) && (( sel-- )) || true ;;
        j) (( sel < n )) && (( sel++ )) || true ;;
        q) break ;;
        $'\n'|$'\r')
          printf '\e[?25h'
          switch_to "${names[sel]}"
          return ;;
      esac
    done
  } always { printf '\e[?25h' }
}

cmd="${1:-}"
case "$cmd" in
  "")
    if [[ -t 0 && -t 1 ]]; then picker; else
      echo "active: $(label_of "$(current)")"
    fi ;;
  status)
    echo "active: $(label_of "$(current)")" ;;
  *)
    if [[ "$cmd" == claude ]] || jq -e --arg n "$cmd" 'has($n)' "$PROV" > /dev/null; then
      switch_to "$cmd"
    else
      echo "unknown provider '$cmd' — choices: ${names[*]} (or: m status)" >&2
      exit 2
    fi ;;
esac
