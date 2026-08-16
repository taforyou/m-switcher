#!/bin/zsh
# m — switch Claude Code between providers in ~/.claude/settings.json
#
#   m                         interactive provider picker
#   m openrouter              choose an OpenRouter model and endpoint
#   m openrouter Q            start model search at "Q"
#   m openrouter <model> <endpoint-tag>
#   m key openrouter          securely save/validate an API key
#   m models openrouter [query]
#   m endpoints openrouter <model> [query]
#   m claude                  return to the Anthropic default
#   m status                  print the active provider/model/endpoint
#
# Providers live in ~/.claude/providers.json. Paths can be overridden with
# M_SETTINGS, M_CLAUDE_JSON, and M_PROVIDERS for testing.

emulate -R zsh   # ignore user options from ~/.zshenv (noclobber, ksharrays, ...)
set -e
umask 077        # every file m creates (settings, backups, temp files) is private
SETTINGS="${M_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="${M_CLAUDE_JSON:-$HOME/.claude.json}"
PROV="${M_PROVIDERS:-$HOME/.claude/providers.json}"

if [[ ! -f "$SETTINGS" ]]; then
  # Claude Code creates settings.json on first launch; a fresh install can
  # run m before that, so create an empty one instead of refusing to start.
  if [[ -d "${SETTINGS:h}" ]]; then
    printf '{}\n' > "$SETTINGS"
    echo "note: created $SETTINGS" >&2
  else
    echo "missing $SETTINGS (directory ${SETTINGS:h} does not exist; run claude once or create it)" >&2
    exit 1
  fi
fi
[[ -f "$PROV" ]] || { echo "missing $PROV" >&2; exit 1; }
# Write through symlinks (dotfiles setups) instead of replacing them.
SETTINGS="${SETTINGS:A}"
PROV="${PROV:A}"
CLAUDE_JSON="${CLAUDE_JSON:A}"

names=(claude ${(f)"$(jq -r 'keys_unsorted[]' "$PROV")"})
HTTP_DATA=""
HTTP_STATUS=""
MODEL_DATA=""
ENDPOINT_DATA=""
DISCOUNT_CATALOG_STATUS="unloaded"
DISCOUNT_CATALOG_ERROR=""
SELECTED_MODEL=""
SELECTED_ENDPOINT=""
SELECTED_ENDPOINT_NAME=""
SELECTED_CONTEXT_LENGTH=""
KEY_VALIDATED=0
typeset -ga M_TMP_FILES
M_CURSOR_HIDDEN=0
M_SAVED_STTY=""
M_PICKER_WIDTH=79

# zsh `always` blocks do not run when the shell dies from a signal or an
# errexit, so terminal state and temp files are also cleaned up from traps.
cleanup() {
  if (( M_CURSOR_HIDDEN )); then printf '\e[?25h'; M_CURSOR_HIDDEN=0; fi
  if [[ -n "$M_SAVED_STTY" ]]; then stty "$M_SAVED_STTY" 2>/dev/null || true; M_SAVED_STTY=""; fi
  if (( ${#M_TMP_FILES} )); then rm -f -- "${M_TMP_FILES[@]}"; M_TMP_FILES=(); fi
  return 0
}
trap 'cleanup; trap - INT; kill -INT $$; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup' EXIT

usage() {
  cat <<'EOF'
usage:
  m                                  interactive provider picker
  m <provider> [model] [endpoint]    switch directly
  m key <provider>                   securely set the provider API key
  m models <provider> [query]        list available models
  m endpoints <provider> <model> [query]
                                     list model hosting endpoints and prices
  m claude                           use Anthropic directly
  m status                           show the active route
EOF
}

is_provider() {
  [[ "$1" == claude ]] || jq -e --arg n "$1" 'has($n)' "$PROV" >/dev/null
}

label_of() {
  if [[ "$1" == claude ]]; then
    echo "claude (anthropic default)"
  else
    jq -r --arg n "$1" '.[$n].label // $n' "$PROV"
  fi
}

has_catalog() {
  jq -e --arg n "$1" '.[$n].modelCatalog.url? | type == "string" and length > 0' "$PROV" >/dev/null
}

credential_of() {
  jq -r --arg n "$1" '
    [.[$n].env.ANTHROPIC_AUTH_TOKEN?, .[$n].env.ANTHROPIC_API_KEY?]
    | map(select(type == "string" and length > 0))
    | .[0] // ""
  ' "$PROV"
}

credential_env_of() {
  jq -r --arg n "$1" '
    if .[$n].env | has("ANTHROPIC_AUTH_TOKEN") then "ANTHROPIC_AUTH_TOKEN"
    elif .[$n].env | has("ANTHROPIC_API_KEY") then "ANTHROPIC_API_KEY"
    else ""
    end
  ' "$PROV"
}

credential_is_set() {
  local token
  token="$(credential_of "$1")"
  [[ -n "$token" && "$token" != \<* ]]
}

current() {
  jq -r --slurpfile p "$PROV" '
    (.env.ANTHROPIC_BASE_URL // "") as $b
    | first($p[0] | to_entries[] | select(.value.env.ANTHROPIC_BASE_URL == $b) | .key) // "claude"
  ' "$SETTINGS"
}

current_model() {
  local name="${1:-$(current)}"
  [[ "$name" == claude ]] && return 0
  jq -r --slurpfile p "$PROV" --arg n "$name" '
    ($p[0][$n].modelCatalog.selectionEnv.model // "") as $key
    | [
        (if $key != "" then .env[$key] // "" else "" end),
        (.env.ANTHROPIC_MODEL // ""),
        (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "")
      ]
    | map(select(type == "string" and length > 0))
    | .[0] // ""
  ' "$SETTINGS"
}

current_endpoint() {
  local name="${1:-$(current)}"
  [[ "$name" == claude ]] && return 0
  jq -r --slurpfile p "$PROV" --arg n "$name" '
    ($p[0][$n].modelCatalog.selectionEnv.endpointName // "") as $nameKey
    | ($p[0][$n].modelCatalog.selectionEnv.endpoint // "") as $tagKey
    | if $nameKey != "" and (.env[$nameKey] // "") != "" then .env[$nameKey]
      elif $tagKey != "" then .env[$tagKey] // ""
      else ""
      end
  ' "$SETTINGS"
}

current_context_length() {
  local name="${1:-$(current)}"
  [[ "$name" == claude ]] && return 0
  jq -r --slurpfile p "$PROV" --arg n "$name" '
    ($p[0][$n].modelCatalog.selectionEnv.context // "") as $selectionKey
    | ($p[0][$n].modelCatalog.contextEnv.max // "") as $contextKey
    | if $selectionKey != "" and (.env[$selectionKey] // "") != "" then .env[$selectionKey]
      elif $contextKey != "" then .env[$contextKey] // ""
      else ""
      end
  ' "$SETTINGS"
}

print_status() {
  local name model endpoint context_length
  name="$(current)"
  model="$(current_model "$name")"
  endpoint="$(current_endpoint "$name")"
  context_length="$(current_context_length "$name")"
  printf 'active: %s' "$(label_of "$name")"
  [[ -n "$model" ]] && printf ' — model: %s' "$model"
  [[ -n "$endpoint" ]] && printf ' — endpoint: %s' "$endpoint"
  [[ -n "$context_length" ]] && printf ' — context: %s tokens' "$context_length"
  printf '\n'
}

# Makes an HTTP request, adding bearer authentication when a token is given
# without putting that token in curl's process arguments. Results are returned
# through HTTP_STATUS and HTTP_DATA.
http_request() {
  local method="$1" url="$2" token="$3" payload="${4:-}"
  local prefix="${TMPDIR:-/tmp}/m-switcher-http"
  local header_file response_file payload_file=""
  local -a args
  header_file="$(mktemp "${prefix}.header.XXXXXX")"
  response_file="$(mktemp "${prefix}.response.XXXXXX")"
  chmod 600 "$header_file" "$response_file"
  M_TMP_FILES+=("$header_file" "$response_file")
  if [[ -n "$payload" ]]; then
    payload_file="$(mktemp "${prefix}.payload.XXXXXX")"
    chmod 600 "$payload_file"
    M_TMP_FILES+=("$payload_file")
  fi
  {
    [[ -n "$token" ]] && printf 'Authorization: Bearer %s\n' "$token" > "$header_file"
    [[ -n "$payload_file" ]] && printf '%s' "$payload" > "$payload_file"
    # -q must come first: it stops curl from reading ~/.curlrc, whose
    # verbose/trace options would print the Authorization header.
    args=(-q -sS --connect-timeout 10 --max-time 30 -o "$response_file" -w '%{http_code}'
          -X "$method")
    [[ -n "$token" ]] && args+=(-H "@$header_file")
    if [[ -n "$payload_file" ]]; then
      args+=(-H 'Content-Type: application/json' --data-binary "@$payload_file")
    fi
    if ! HTTP_STATUS="$(curl "${args[@]}" "$url")"; then
      echo "unable to reach $url" >&2
      return 1
    fi
    HTTP_DATA="$(<"$response_file")"
  } always {
    rm -f "$header_file" "$response_file"
    [[ -n "$payload_file" ]] && rm -f "$payload_file"
  }
}

http_succeeded() {
  (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 ))
}

print_api_error() {
  local fallback="${1:-API request failed}"
  local message
  message="$(printf '%s' "$HTTP_DATA" | jq -r '.error.message? // empty' 2>/dev/null || true)"
  [[ -n "$message" ]] || message="$fallback"
  echo "$message (HTTP $HTTP_STATUS)" >&2
}

# Sets KEY_VALIDATED=1 only when the provider has a validationUrl and the key
# passed it; providers without one (Z.ai, Kimi) are saved unvalidated.
validate_key() {
  local name="$1" token="$2" url
  KEY_VALIDATED=0
  url="$(jq -r --arg n "$name" '.[$n].modelCatalog.validationUrl // ""' "$PROV")"
  [[ -z "$url" ]] && return 0
  http_request GET "$url" "$token" || return 1
  if ! http_succeeded; then
    print_api_error "API key validation failed"
    return 1
  fi
  printf '%s' "$HTTP_DATA" | jq -e '.data? != null' >/dev/null 2>&1 || {
    echo "API key validation returned an unexpected response" >&2
    return 1
  }
  KEY_VALIDATED=1
}

configure_key() {
  local name="$1" key_env token tmp
  [[ "$name" != claude ]] && is_provider "$name" || {
    echo "unknown provider '$name'" >&2
    return 2
  }
  key_env="$(credential_env_of "$name")"
  [[ -n "$key_env" ]] || {
    echo "provider '$name' has no ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY field" >&2
    return 2
  }

  if [[ -t 0 ]]; then
    printf 'API key for %s (input hidden): ' "$(label_of "$name")" >&2
    IFS= read -rs token
    printf '\n' >&2
  else
    IFS= read -r token
  fi
  [[ -n "$token" && "$token" != \<* ]] || {
    echo "refusing: API key cannot be empty or a placeholder" >&2
    return 3
  }
  validate_key "$name" "$token" || return 3

  tmp="$(mktemp "$PROV.XXXXXX")"
  M_TMP_FILES+=("$tmp")
  # The token reaches jq through the environment, never through argv.
  if ! value="$token" jq --arg n "$name" --arg key "$key_env" \
       '.[$n].env[$key] = env.value' "$PROV" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  cp "$PROV" "$PROV.bak"
  chmod 600 "$PROV.bak"   # cp keeps a pre-existing .bak's (possibly 644) mode
  mv "$tmp" "$PROV"
  if (( KEY_VALIDATED )); then
    echo "saved and validated API key for $(label_of "$name")"
  else
    echo "saved API key for $(label_of "$name") (not validated: provider has no validationUrl)"
  fi
}

ensure_credential() {
  local name="$1"
  credential_is_set "$name" && return 0
  if [[ -t 0 && -t 1 ]]; then
    echo "API key for '$(label_of "$name")' is not configured."
    configure_key "$name"
  else
    echo "refusing: API key for '$name' is not set in $PROV" >&2
    echo "run: m key $name" >&2
    return 3
  fi
}

fetch_models() {
  local name="$1" token url special exclude
  token="$(credential_of "$name")"
  url="$(jq -r --arg n "$name" '.[$n].modelCatalog.url // ""' "$PROV")"
  [[ -n "$url" ]] || { echo "provider '$name' has no model catalog" >&2; return 2; }
  http_request GET "$url" "$token" || return 1
  if ! http_succeeded; then
    print_api_error "unable to load models"
    return 1
  fi
  printf '%s' "$HTTP_DATA" | jq -e '.data | type == "array"' >/dev/null 2>&1 || {
    echo "model catalog returned an unexpected response" >&2
    return 1
  }
  special="$(jq -c --arg n "$name" '.[$n].modelCatalog.specialModels // []' "$PROV")"
  # excludeIdSuffixes drops catalog variants that are not usable for an
  # interactive Claude Code session (OpenRouter's ":batch" Batch-API models).
  # Filtering here also makes model_exists reject them.
  exclude="$(jq -c --arg n "$name" '.[$n].modelCatalog.excludeIdSuffixes // []' "$PROV")"
  MODEL_DATA="$(printf '%s' "$HTTP_DATA" | jq -c --argjson special "$special" --argjson exclude "$exclude" '
    .data as $models
    | .data = ($special + [
        $models[] | .id as $id
        | select(($special | any(.id == $id)) | not)
        | select(($exclude | any(. as $s | $id | endswith($s))) | not)
      ])
  ')"
  DISCOUNT_CATALOG_STATUS="unloaded"
  DISCOUNT_CATALOG_ERROR=""
}

model_rows() {
  local query="${1:l}" scope="${2:-all}"
  printf '%s' "$MODEL_DATA" | jq -r --arg q "$query" --arg scope "$scope" '
    def clean: gsub("[[:cntrl:]]"; " ");
    def lower: ascii_downcase;
    def number($value): try ($value | tonumber) catch null;
    def input_price: number(.pricing.prompt);
    def output_price: number(.pricing.completion);
    def request_price: number(.pricing.request) // 0;
    def is_free:
      .id == "openrouter/free"
      or (.id | endswith(":free"))
      or (input_price == 0 and output_price == 0 and request_price == 0);
    def price_total:
      if input_price == null or output_price == null then 0
      else (input_price + output_price) * 1000000
      end;
    def price_group:
      if is_free then 0
      elif input_price == null or output_price == null then 1
      else 2
      end;
    def price_level:
      if is_free then 0
      elif input_price == null or output_price == null then -1
      else price_total as $per_million
      | if $per_million <= 1 then 1
        elif $per_million <= 3 then 2
        elif $per_million <= 8 then 3
        elif $per_million <= 20 then 4
        elif $per_million < 30 then 5
        else 6 end
      end;
    def fmt_price($value):
      if $value == null then "?"
      else ($value * 1000000) as $per_million
      | (((($per_million * 10000) | round) / 10000) | tostring)
      end;
    def rank($q):
      if $q == "" then 0
      elif ((.id // "" | lower) | startswith($q))
        or ((.name // "" | lower) | startswith($q)) then 0
      elif ((.id // "" | lower) | contains($q))
        or ((.name // "" | lower) | contains($q)) then 1
      else 2 end;
    .data
    | map(. + {
        "_m_rank": rank($q),
        "_m_price": price_total,
        "_m_price_group": price_group
      })
    | map(select(
        $scope == "all"
        or ($scope == "discounted" and ._m_discounted == true)
        or ($scope == "free" and is_free)
    ))
    | map(select(._m_rank < 2))
    | if $scope == "discounted" then
        sort_by(._m_rank, -(._m_discount // 0), -._m_price)
      elif $scope == "free" then
        sort_by(._m_rank, -(.context_length // 0))
      else
        sort_by(._m_rank, -._m_price_group, -._m_price)
      end
    | .[]
    | [
        .id,
        ((.name // .id) | clean),
        (if (.context_length // 0) >= 1000000
         then (((.context_length / 1000000 * 10) | floor) / 10 | tostring) + "M"
         else (((.context_length // 0) / 1000 | floor | tostring) + "k") end),
        (price_level | tostring),
        (if $scope == "discounted" then
           (((((._m_discount // 0) * 100) + 0.5) | floor) | tostring)
         else "" end),
        (if is_free then "free"
         elif input_price == null or output_price == null then "price n/a"
         else "$" + fmt_price(input_price) + "/$" + fmt_price(output_price) + "/M"
         end)
      ]
    | @tsv
  '
}

# OpenRouter's Models API exposes the cheapest live price but not whether that
# price is promotional. Its discounted collection is the authoritative live
# list, so load it only if the user enters the Discounted picker scope. The
# collection is a Next.js stream containing escaped structured model records;
# exact slug fields are extracted and then intersected with the API catalog.
fetch_discounted_models() {
  local name="$1" url discounts
  [[ "$DISCOUNT_CATALOG_STATUS" == loaded ]] && return 0
  [[ "$DISCOUNT_CATALOG_STATUS" == unavailable ]] && return 1

  url="$(jq -r --arg n "$name" '.[$n].modelCatalog.discountedModelsUrl // ""' "$PROV")"
  if [[ -z "$url" ]]; then
    DISCOUNT_CATALOG_STATUS="unavailable"
    DISCOUNT_CATALOG_ERROR="discounted scope is not configured"
    return 1
  fi
  # The collection is a public web page. Never send an API credential to a
  # non-API URL, even though it shares OpenRouter's origin.
  if ! http_request GET "$url" "" || ! http_succeeded; then
    DISCOUNT_CATALOG_STATUS="unavailable"
    DISCOUNT_CATALOG_ERROR="discounted list unavailable"
    return 1
  fi
  discounts="$(printf '%s' "$HTTP_DATA" | jq -Rsc '
    [scan("\\{\\\\\"model\\\\\":\\{\\\\\"slug\\\\\":\\\\\"([^\\\\\"]+)\\\\\".*?\\\\\"discount\\\\\":([0-9.]+)")
     | {id: .[0], discount: (.[1] | tonumber)}]
    | group_by(.id)
    | map({id: .[0].id, discount: (map(.discount) | max)})
  ' 2>/dev/null || true)"
  if [[ -z "$discounts" ]] \
     || ! printf '%s' "$discounts" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    DISCOUNT_CATALOG_STATUS="unavailable"
    DISCOUNT_CATALOG_ERROR="discounted list format changed"
    return 1
  fi
  MODEL_DATA="$(printf '%s' "$MODEL_DATA" | jq -c --argjson discounts "$discounts" '
    ($discounts | map({key: .id, value: .discount}) | from_entries) as $by_id
    | .data |= map(.id as $id | . + {
        "_m_discounted": ($by_id[$id] != null),
        "_m_discount": ($by_id[$id] // 0)
      })
  ')"
  DISCOUNT_CATALOG_STATUS="loaded"
  DISCOUNT_CATALOG_ERROR=""
}

model_exists() {
  printf '%s' "$MODEL_DATA" | jq -e --arg id "$1" 'any(.data[]; .id == $id)' >/dev/null
}

model_context_length() {
  printf '%s' "$MODEL_DATA" | jq -r --arg id "$1" '
    first(.data[] | select(.id == $id) | (.context_length // 0 | floor)) // 0
  '
}

model_routes_directly() {
  local name="$1" model="$2"
  jq -e --arg n "$name" --arg model "$model" '
    any((.[$n].modelCatalog.specialModels // [])[];
        .id == $model and .direct == true)
  ' "$PROV" >/dev/null
}

# --- interactive pickers ----------------------------------------------------
# All three pickers redraw a fixed number of lines in place, so every line is
# clipped to the terminal width (a wrapped line would shift the frame), the
# cursor is hidden and the tty is kept raw for the whole picker; cleanup()
# undoes both on signals, picker_leave() on the normal path.

picker_enter() {
  local cols
  cols="$(tput cols 2>/dev/null || true)"
  [[ "$cols" == <-> && cols -gt 0 ]] || cols="${COLUMNS:-80}"
  [[ "$cols" == <-> && cols -gt 0 ]] || cols=80
  M_PICKER_WIDTH=$(( cols - 1 ))
  if [[ -z "$M_SAVED_STTY" ]]; then
    M_SAVED_STTY="$(stty -g 2>/dev/null || true)"
    # Raw/no-echo for the whole picker: zsh's read -k restores cooked mode
    # between keys, and a key arriving during a redraw would otherwise be
    # echoed onto the frame (or a backspace swallowed by the line discipline).
    [[ -n "$M_SAVED_STTY" ]] && { stty -icanon -echo min 1 time 0 2>/dev/null || true; }
  fi
  printf '\e[?25l'
  M_CURSOR_HIDDEN=1
}

picker_leave() {
  if (( M_CURSOR_HIDDEN )); then printf '\e[?25h'; M_CURSOR_HIDDEN=0; fi
  if [[ -n "$M_SAVED_STTY" ]]; then stty "$M_SAVED_STTY" 2>/dev/null || true; M_SAVED_STTY=""; fi
  return 0
}

# Prints one picker line clipped to the terminal width. Cost styles preserve
# the model's green-to-red price signal even on the selected (bold) row.
picker_line() {
  local text="$1" style="${2:-}" level color
  local -a cost_colors=(46 82 118 226 214 208 196)
  text="${text[1,M_PICKER_WIDTH]}"
  case "$style" in
    hl)  printf '\e[K\e[36m%s\e[0m\n' "$text" ;;
    dim) printf '\e[K\e[2m%s\e[0m\n' "$text" ;;
    cost:<->)
      level="${style#cost:}"
      color="${cost_colors[level + 1]}"
      printf '\e[K\e[38;5;%sm%s\e[0m\n' "$color" "$text" ;;
    cost-hl:<->)
      level="${style#cost-hl:}"
      color="${cost_colors[level + 1]}"
      printf '\e[K\e[1;38;5;%sm%s\e[0m\n' "$color" "$text" ;;
    *)   printf '\e[K%s\n' "$text" ;;
  esac
}

# Reads one keypress into REPLY: directions, tab, enter, backspace, esc (a lone
# Escape or EOF), char:<c> for a printable character, or other for any complete
# escape sequence m does not use, which the pickers ignore instead of aborting.
read_key() {
  local key rest ch
  REPLY=other
  read -sk1 key || { REPLY=esc; return 0; }
  case "$key" in
    $'\e')
      rest=""
      while read -sk1 -t 0.05 ch 2>/dev/null; do
        rest+="$ch"
        if [[ "$rest" == \[* ]]; then
          # CSI: ESC [ parameters... final byte 0x40-0x7E
          (( ${#rest} > 1 && #ch >= 64 && #ch <= 126 )) && break
        elif [[ "$rest" == O* ]]; then
          # SS3: ESC O <one byte> (application-mode arrows)
          (( ${#rest} >= 2 )) && break
        else
          break   # Alt/Option+key or another two-byte sequence
        fi
      done
      case "$rest" in
        '')        REPLY=esc ;;
        '[A'|'OA') REPLY=up ;;
        '[B'|'OB') REPLY=down ;;
        '[C'|'OC') REPLY=right ;;
        '[D'|'OD') REPLY=left ;;
        *)         REPLY=other ;;
      esac ;;
    $'\t')          REPLY=tab ;;
    $'\x7f'|$'\b') REPLY=backspace ;;
    $'\n'|$'\r')   REPLY=enter ;;
    *) [[ "$key" == [[:print:]] ]] && REPLY="char:$key" ;;
  esac
  return 0
}

model_picker() {
  local name="$1" query="${2:-}" sel=1 page_size=10 first=1 active_model scope_index=1 scope=all
  local row id tail display context price_level discount price_label mark text i total start index header
  local -a rows scope_names=(all discounted free)
  SELECTED_MODEL=""
  active_model="$(current_model 2>/dev/null || true)"
  picker_enter
  {
    while true; do
      rows=(${(f)"$(model_rows "$query" "$scope")"})
      total=${#rows}
      (( total == 0 )) && sel=1
      (( total > 0 && sel > total )) && sel=$total
      (( sel < 1 )) && sel=1
      start=$(( total == 0 ? 0 : ((sel - 1) / page_size) * page_size ))

      (( first )) || printf '\e[13A'
      first=0
      case "$scope" in
        all)        header="Models: [All]  Discounted  Free" ;;
        discounted) header="Models: All  [Discounted]  Free" ;;
        free)       header="Models: All  Discounted  [Free]" ;;
      esac
      if [[ "$scope" == discounted && "$DISCOUNT_CATALOG_STATUS" == unavailable ]]; then
        header+=" — $DISCOUNT_CATALOG_ERROR"
      elif (( total == 1 )); then
        header+=" — 1 match"
      else
        header+=" — $total matches"
      fi
      picker_line "$header"
      picker_line "Search: $query"
      for i in {1..$page_size}; do
        index=$(( start + i ))
        if (( index <= total )); then
          row="${rows[index]}"
          id="${row%%$'\t'*}"
          tail="${row#*$'\t'}"
          display="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          context="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          price_level="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          discount="${tail%%$'\t'*}"
          price_label="${tail#*$'\t'}"
          mark=" "
          [[ "$id" == "$active_model" ]] && mark="o"
          (( index == sel )) && [[ "$mark" == " " ]] && mark=">"
          if [[ "$scope" == discounted ]]; then
            text="  ${mark} [${discount}%] ${display} — ${id} (${context}, ${price_label})"
          else
            text="  ${mark} ${display} — ${id} (${context}, ${price_label})"
          fi
          if (( price_level >= 0 )); then
            if (( index == sel )); then
              picker_line "$text" "cost-hl:$price_level"
            else
              picker_line "$text" "cost:$price_level"
            fi
          elif (( index == sel )); then
            picker_line "$text" hl
          else
            picker_line "$text"
          fi
        else
          picker_line ""
        fi
      done
      picker_line "←/→ scope · green→red price · search typing · ↑/↓ move · enter · esc cancel" dim

      read_key
      case "$REPLY" in
        up)   (( sel > 1 )) && (( sel-- )) || true ;;
        down) (( sel < total )) && (( sel++ )) || true ;;
        left)
          if (( scope_index > 1 )); then
            (( scope_index-- ))
            scope="${scope_names[scope_index]}"
            (( scope_index == 2 )) && fetch_discounted_models "$name" || true
            sel=1
          fi ;;
        right)
          if (( scope_index < 3 )); then
            (( scope_index++ ))
            scope="${scope_names[scope_index]}"
            (( scope_index == 2 )) && fetch_discounted_models "$name" || true
            sel=1
          fi ;;
        tab)
          scope_index=$(( scope_index % 3 + 1 ))
          scope="${scope_names[scope_index]}"
          (( scope_index == 2 )) && fetch_discounted_models "$name" || true
          sel=1 ;;
        backspace)
          if (( ${#query} > 0 )); then query="${query[1,-2]}"; sel=1; fi ;;
        enter)
          if (( total > 0 )); then
            row="${rows[sel]}"
            SELECTED_MODEL="${row%%$'\t'*}"
            return 0
          fi ;;
        esc) return 130 ;;
        char:*)
          if (( ${#query} < 60 )); then
            query+="${REPLY#char:}"
            sel=1
          fi ;;
      esac
    done
  } always {
    picker_leave
  }
}

fetch_endpoints() {
  local name="$1" model="$2" token base url
  token="$(credential_of "$name")"
  base="$(jq -r --arg n "$name" '.[$n].modelCatalog.endpointsUrl // ""' "$PROV")"
  [[ -n "$base" ]] || { echo "provider '$name' does not support endpoint selection" >&2; return 2; }
  url="${base%/}/$model/endpoints"
  http_request GET "$url" "$token" || return 1
  if ! http_succeeded; then
    print_api_error "unable to load model endpoints"
    return 1
  fi
  printf '%s' "$HTTP_DATA" | jq -e '.data.endpoints | type == "array"' >/dev/null 2>&1 || {
    echo "endpoint catalog returned an unexpected response" >&2
    return 1
  }
  ENDPOINT_DATA="$HTTP_DATA"
}

endpoint_rows() {
  local query="${1:l}"
  printf '%s' "$ENDPOINT_DATA" | jq -r --arg q "$query" '
    def clean: gsub("[[:cntrl:]]"; " ");
    def lower: ascii_downcase;
    def price: ((.pricing.prompt | tonumber?) // 999999)
             + ((.pricing.completion | tonumber?) // 999999);
    def rank($q):
      if $q == "" then 0
      elif ((.provider_name // "" | lower) | startswith($q))
        or ((.tag // "" | lower) | startswith($q)) then 0
      elif ((.provider_name // "" | lower) | contains($q))
        or ((.tag // "" | lower) | contains($q)) then 1
      else 2 end;
    def fmt_context:
      if . >= 1000000 then (((. / 1000000 * 10) | floor) / 10 | tostring) + "M"
      else ((. / 1000 | floor | tostring) + "k") end;
    .data.endpoints
    | map(select((.status // 0) == 0 and ((.supported_parameters // []) | index("tools"))))
    | map(. + {"_m_rank": rank($q), "_m_price": price})
    | map(select(._m_rank < 2))
    | sort_by(._m_rank, ._m_price)
    | .[]
    | [
        .tag,
        ((.provider_name // .tag) | clean),
        ((((((.pricing.prompt | tonumber?) // 0) * 1000000000000) | round) / 1000000) | tostring),
        ((((((.pricing.completion | tonumber?) // 0) * 1000000000000) | round) / 1000000) | tostring),
        (((((.pricing.discount // 0) * 100) + 0.5) | floor) | tostring),
        (.quantization // "unknown"),
        ((.context_length // 0 | floor) | fmt_context),
        ((.context_length // 0 | floor) | tostring)
      ]
    | @tsv
  '
}

endpoint_details() {
  local tag="$1"
  printf '%s' "$ENDPOINT_DATA" | jq -r --arg tag "$tag" '
    first(.data.endpoints[]
      | select(.tag == $tag and (.status // 0) == 0
               and ((.supported_parameters // []) | index("tools")))
      | [.tag, (.provider_name // .tag), (.context_length // 0 | floor)] | @tsv) // ""
  '
}

endpoint_picker() {
  local query="${1:-}" sel=1 page_size=10 first=1 cheapest_tag
  local row tag tail display input_price output_price discount quant context mark text i total start index
  local -a rows
  SELECTED_ENDPOINT=""
  SELECTED_ENDPOINT_NAME=""
  SELECTED_CONTEXT_LENGTH=""
  # '*' marks the cheapest healthy endpoint of the whole list, whatever the
  # current search shows (search results are ranked by match, then price).
  cheapest_tag="$(endpoint_rows "" | head -n 1)"
  cheapest_tag="${cheapest_tag%%$'\t'*}"
  picker_enter
  {
    while true; do
      rows=(${(f)"$(endpoint_rows "$query")"})
      total=${#rows}
      (( total == 0 )) && sel=1
      (( total > 0 && sel > total )) && sel=$total
      (( sel < 1 )) && sel=1
      start=$(( total == 0 ? 0 : ((sel - 1) / page_size) * page_size ))

      (( first )) || printf '\e[13A'
      first=0
      picker_line "Hosting endpoints — cheapest is selected by default ($total matches)"
      picker_line "Search: $query"
      for i in {1..$page_size}; do
        index=$(( start + i ))
        if (( index <= total )); then
          row="${rows[index]}"
          tag="${row%%$'\t'*}"; tail="${row#*$'\t'}"
          display="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          input_price="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          output_price="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          discount="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          quant="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          context="${tail%%$'\t'*}"
          mark=" "
          [[ -n "$cheapest_tag" && "$tag" == "$cheapest_tag" ]] && mark="*"
          text="  ${mark} ${display} [${tag}] \$${input_price}/\$${output_price}/M ${quant} ${context}"
          (( discount > 0 )) && text+=" (${discount}% off)"
          if (( index == sel )); then picker_line "$text" hl; else picker_line "$text"; fi
        else
          picker_line ""
        fi
      done
      picker_line "* cheapest; type to search, arrows move, return pins, esc cancels" dim

      read_key
      case "$REPLY" in
        up)   (( sel > 1 )) && (( sel-- )) || true ;;
        down) (( sel < total )) && (( sel++ )) || true ;;
        backspace)
          if (( ${#query} > 0 )); then query="${query[1,-2]}"; sel=1; fi ;;
        enter)
          if (( total > 0 )); then
            row="${rows[sel]}"
            SELECTED_ENDPOINT="${row%%$'\t'*}"
            tail="${row#*$'\t'}"
            SELECTED_ENDPOINT_NAME="${tail%%$'\t'*}"
            SELECTED_CONTEXT_LENGTH="${row##*$'\t'}"
            return 0
          fi ;;
        esc) return 130 ;;
        char:*)
          if (( ${#query} < 60 )); then
            query+="${REPLY#char:}"
            sel=1
          fi ;;
      esac
    done
  } always {
    picker_leave
  }
}

preset_slug() {
  local model="$1" endpoint="$2" base checksum
  base="$(jq -nr --arg value "$model--$endpoint" '
    $value | ascii_downcase | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | .[0:80]
  ')"
  checksum="$(printf '%s' "$model|$endpoint" | cksum | awk '{print $1}')"
  printf 'm-switcher-%s-%s\n' "$base" "$checksum"
}

ensure_routing_preset() {
  local name="$1" model="$2" endpoint="$3" token base slug url payload ignore
  token="$(credential_of "$name")"
  base="$(jq -r --arg n "$name" '.[$n].modelCatalog.presetsUrl // ""' "$PROV")"
  [[ -n "$base" ]] || { echo "provider '$name' does not support exact endpoint routing" >&2; return 2; }
  slug="$(preset_slug "$model" "$endpoint")"
  url="${base%/}/$slug"

  # A bare provider slug in provider.only (e.g. "fireworks") also matches that
  # provider's suffixed endpoints ("fireworks/fast", regions) under OpenRouter's
  # base-slug matching, so every sibling tag of the model is excluded
  # explicitly. Suffixed tags such as "streamlake/fp8" are already exact.
  ignore="$(printf '%s' "$ENDPOINT_DATA" | jq -c --arg tag "$endpoint" '
    [.data.endpoints[]? | .tag // empty | select(. != $tag and startswith($tag + "/"))]
    | unique
  ' 2>/dev/null || true)"
  [[ -n "$ignore" ]] || ignore="[]"

  # Reuse an identical preset. This avoids creating a new preset version each
  # time the same model/endpoint route is selected.
  http_request GET "$url" "$token" || return 1
  if [[ "$HTTP_STATUS" == 200 ]] && printf '%s' "$HTTP_DATA" | jq -e \
       --arg model "$model" --arg endpoint "$endpoint" --argjson ignore "$ignore" '
       .data.designated_version.config as $c
       | $c.model == $model
         and $c.provider.only == [$endpoint]
         and $c.provider.allow_fallbacks == false
         and (($c.provider.ignore // []) | sort) == ($ignore | sort)
     ' >/dev/null 2>&1; then
    printf '@preset/%s\n' "$slug"
    return 0
  elif [[ "$HTTP_STATUS" != 200 && "$HTTP_STATUS" != 404 ]]; then
    print_api_error "unable to inspect OpenRouter routing preset"
    return 1
  fi

  payload="$(jq -nc --arg model "$model" --arg endpoint "$endpoint" --argjson ignore "$ignore" '{
    model: $model,
    messages: [{role: "user", content: "m-switcher routing preset"}],
    provider: ({
      only: [$endpoint],
      allow_fallbacks: false
    } + (if ($ignore | length) > 0 then {ignore: $ignore} else {} end))
  }')"
  http_request POST "${url}/messages" "$token" "$payload" || return 1
  if ! http_succeeded; then
    print_api_error "unable to create OpenRouter routing preset"
    return 1
  fi
  printf '%s' "$HTTP_DATA" | jq -e '.data.slug? | type == "string"' >/dev/null 2>&1 || {
    echo "preset API returned an unexpected response" >&2
    return 1
  }
  printf '@preset/%s\n' "$slug"
}

switch_to() {
  local name="$1" route="${2:-}" selected_model="${3:-}"
  local endpoint="${4:-}" endpoint_name="${5:-}"
  local context_length="${6:-}"
  local effective_route="$route" override_key="" override_value="" override_conflict=""
  local desired_override_key existing_override owned_override_key owned_override_value
  if [[ "$name" != claude ]] && ! credential_is_set "$name"; then
    echo "refusing: API key for '$name' is not set in $PROV" >&2
    echo "run: m key $name" >&2
    return 3
  fi

  # Claude Code 2.1.233+ emits an unrecognized-model diagnostic for gateway
  # aliases. A modelOverride silences it, but also makes Claude Code use that
  # Anthropic model's built-in context size. Only add the mapping for windows
  # we can represent without lying: exactly 200K, or a genuine >=1M route with
  # Claude Code's provider-stripped [1m] suffix.
  owned_override_key="$(jq -r --slurpfile p "$PROV" '
    (.env.ANTHROPIC_BASE_URL // "") as $base
    | (first($p[0] | to_entries[]
        | select(.value.env.ANTHROPIC_BASE_URL == $base)) // {}) as $provider
    | ($provider.value.modelCatalog.selectionEnv.overrideKey // "") as $key
    | if $key != "" then .env[$key] // "" else "" end
  ' "$SETTINGS")"
  owned_override_value="$(jq -r --slurpfile p "$PROV" '
    (.env.ANTHROPIC_BASE_URL // "") as $base
    | (first($p[0] | to_entries[]
        | select(.value.env.ANTHROPIC_BASE_URL == $base)) // {}) as $provider
    | ($provider.value.modelCatalog.selectionEnv.overrideValue // "") as $key
    | if $key != "" then .env[$key] // "" else "" end
  ' "$SETTINGS")"

  if [[ "$name" != claude && -n "$route" && -n "$context_length" ]] \
     && (( context_length == 200000 || context_length >= 1000000 )); then
    desired_override_key="$(jq -r --arg n "$name" \
      '.[$n].modelCatalog.recognitionOverride // ""' "$PROV")"
    if [[ -n "$desired_override_key" ]]; then
      (( context_length >= 1000000 )) && effective_route="${route}[1m]"
      existing_override="$(jq -r --arg key "$desired_override_key" \
        '(.modelOverrides // {})[$key] // ""' "$SETTINGS")"
      if [[ -z "$existing_override" \
            || ( "$owned_override_key" == "$desired_override_key" \
                 && "$existing_override" == "$owned_override_value" ) ]]; then
        override_key="$desired_override_key"
        override_value="$route"
      elif [[ "$existing_override" != "$route" ]]; then
        override_conflict="$desired_override_key"
      fi
    fi
  fi

  # Provider-declared ~/.claude.json flags (e.g. Kimi onboarding flags) are
  # prepared and validated before anything is committed, so a broken
  # ~/.claude.json can never leave settings.json half-switched.
  local cj tmp2=""
  cj="$(jq -c --arg n "$name" 'if $n == "claude" then {} else .[$n].claudeJson // {} end' "$PROV")"
  if [[ "$cj" != "{}" ]]; then
    if [[ -s "$CLAUDE_JSON" ]]; then
      if ! jq -e 'type == "object"' "$CLAUDE_JSON" >/dev/null 2>&1; then
        echo "refusing: $CLAUDE_JSON is not a JSON object; fix or move it aside, then retry" >&2
        return 1
      fi
      if ! jq -e --argjson add "$cj" '. + $add == .' "$CLAUDE_JSON" >/dev/null 2>&1; then
        tmp2="$(mktemp "${CLAUDE_JSON}.XXXXXX")"
        M_TMP_FILES+=("$tmp2")
        if ! jq --argjson add "$cj" '. + $add' "$CLAUDE_JSON" > "$tmp2"; then
          rm -f "$tmp2"
          echo "unable to update $CLAUDE_JSON" >&2
          return 1
        fi
      fi
    else
      # Missing or empty: start from the provider's flags alone.
      tmp2="$(mktemp "${CLAUDE_JSON}.XXXXXX")"
      M_TMP_FILES+=("$tmp2")
      printf '%s\n' "$cj" > "$tmp2"
    fi
  fi

  local tmp
  tmp="$(mktemp "$SETTINGS.XXXXXX")"
  M_TMP_FILES+=("$tmp")
  if ! jq --slurpfile p "$PROV" --arg name "$name" --arg route "$effective_route" \
       --arg selectedModel "$selected_model" --arg endpoint "$endpoint" \
       --arg endpointName "$endpoint_name" --arg contextLength "$context_length" \
       --arg oldOverrideKey "$owned_override_key" --arg oldOverrideValue "$owned_override_value" \
       --arg overrideKey "$override_key" --arg overrideValue "$override_value" '
       ($p[0] | [
          .[] as $provider
          | ($provider.env // {} | keys[]),
            ($provider.modelCatalog.modelEnv[]?),
            ($provider.modelCatalog.selectionEnv[]?),
            ($provider.modelCatalog.contextEnv[]?)
        ] | unique) as $all
       | if $oldOverrideKey != ""
            and (((.modelOverrides // {})[$oldOverrideKey] // "") == $oldOverrideValue) then
           del(.modelOverrides[$oldOverrideKey])
         else . end
       | if ((.modelOverrides // {}) | length) == 0 then del(.modelOverrides) else . end
       | if $overrideKey != "" then
           .modelOverrides = ((.modelOverrides // {}) + {($overrideKey): $overrideValue})
         else . end
       | .env = ((.env // {}) | with_entries(.key as $k | select(($all | index($k)) | not)))
       | (if $name != "claude" then .env += $p[0][$name].env else . end)
       | if $name != "claude" and $route != "" then
           .env = (reduce ($p[0][$name].modelCatalog.modelEnv[]?) as $key
                    (.env; .[$key] = $route))
         else . end
       | ($p[0][$name].modelCatalog.selectionEnv // {}) as $selection
       | if $name != "claude" and $selectedModel != "" and ($selection.model // "") != "" then
           .env[$selection.model] = $selectedModel
         else . end
       | if $name != "claude" and $endpoint != "" and ($selection.endpoint // "") != "" then
           .env[$selection.endpoint] = $endpoint
         else . end
       | if $name != "claude" and $endpointName != "" and ($selection.endpointName // "") != "" then
           .env[$selection.endpointName] = $endpointName
         else . end
       | if $name != "claude" and $contextLength != "" and ($selection.context // "") != "" then
           .env[$selection.context] = $contextLength
         else . end
       | if $name != "claude" and $overrideKey != "" and ($selection.overrideKey // "") != "" then
           .env[$selection.overrideKey] = $overrideKey
         else . end
       | if $name != "claude" and $overrideValue != "" and ($selection.overrideValue // "") != "" then
           .env[$selection.overrideValue] = $overrideValue
         else . end
       | ($p[0][$name].modelCatalog.contextEnv.max // "") as $contextKey
       | if $name != "claude" and $contextLength != "" and $contextKey != "" then
           .env[$contextKey] = $contextLength
         else . end
       | if .env == {} then del(.env) else . end
     ' "$SETTINGS" > "$tmp"; then
    rm -f "$tmp" ${tmp2:+"$tmp2"}
    return 1
  fi

  # Commit ~/.claude.json first (its flags are harmless without the switch),
  # then settings.json. Backups are forced to mode 600: cp keeps the mode of a
  # pre-existing .bak, and old ones were created 644.
  if [[ -n "$tmp2" ]]; then
    if [[ -f "$CLAUDE_JSON" ]]; then
      cp "$CLAUDE_JSON" "$CLAUDE_JSON.bak"
      chmod 600 "$CLAUDE_JSON.bak"
    fi
    mv "$tmp2" "$CLAUDE_JSON"
  fi
  cp "$SETTINGS" "$SETTINGS.bak"
  chmod 600 "$SETTINGS.bak"
  mv "$tmp" "$SETTINGS"

  printf 'switched to %s' "$(label_of "$name")"
  [[ -n "$selected_model" ]] && printf ' — model: %s' "$selected_model"
  [[ -n "$endpoint_name" ]] && printf ' — endpoint: %s [%s]' "$endpoint_name" "$endpoint"
  [[ -n "$context_length" ]] && printf ' — context: %s tokens' "$context_length"
  printf ' — restart claude to take effect\n'
  if [[ -n "$override_conflict" ]]; then
    printf 'note: kept your existing modelOverrides.%s; Claude Code may still show its unknown-model notice\n' \
      "$override_conflict"
  fi
}

catalog_switch() {
  local name="$1" model_arg="${2:-}" endpoint_arg="${3:-}"
  local model endpoint_line endpoint_name route context_length tail
  ensure_credential "$name" || return
  fetch_models "$name" || return

  if [[ -n "$model_arg" ]] && model_exists "$model_arg"; then
    model="$model_arg"
  elif [[ -n "$model_arg" && -t 0 && -t 1 ]]; then
    model_picker "$name" "$model_arg" || return
    model="$SELECTED_MODEL"
  elif [[ -n "$model_arg" ]]; then
    echo "unknown model '$model_arg'; run: m models $name '$model_arg'" >&2
    return 2
  elif [[ -t 0 && -t 1 ]]; then
    model_picker "$name" || return
    model="$SELECTED_MODEL"
  else
    # Preserve the old scriptable behavior: with no TTY and no model, switch
    # using the provider's configured default model.
    switch_to "$name"
    return
  fi

  # Router models such as openrouter/free choose the concrete model and host
  # per request. They must not be pinned to one endpoint or wrapped in a preset.
  if model_routes_directly "$name" "$model"; then
    [[ -z "$endpoint_arg" ]] || {
      echo "model '$model' selects its endpoint automatically and does not accept an endpoint" >&2
      return 2
    }
    context_length="$(model_context_length "$model")"
    (( context_length > 0 )) || context_length=""
    switch_to "$name" "$model" "$model" "" "" "$context_length"
    return
  fi

  fetch_endpoints "$name" "$model" || return
  if [[ -n "$endpoint_arg" ]]; then
    endpoint_line="$(endpoint_details "$endpoint_arg")"
    [[ -n "$endpoint_line" ]] || {
      echo "endpoint '$endpoint_arg' is unavailable or lacks tool support" >&2
      echo "run: m endpoints $name $model" >&2
      return 2
    }
    SELECTED_ENDPOINT="${endpoint_line%%$'\t'*}"
    tail="${endpoint_line#*$'\t'}"
    SELECTED_ENDPOINT_NAME="${tail%%$'\t'*}"
    SELECTED_CONTEXT_LENGTH="${tail##*$'\t'}"
  elif [[ -t 0 && -t 1 ]]; then
    endpoint_picker || return
  else
    local -a cheapest
    cheapest=(${(f)"$(endpoint_rows "")"})
    (( ${#cheapest} > 0 )) || { echo "no healthy tool-capable endpoints for '$model'" >&2; return 1; }
    endpoint_line="${cheapest[1]}"
    SELECTED_ENDPOINT="${endpoint_line%%$'\t'*}"
    endpoint_line="${endpoint_line#*$'\t'}"
    SELECTED_ENDPOINT_NAME="${endpoint_line%%$'\t'*}"
    SELECTED_CONTEXT_LENGTH="${endpoint_line##*$'\t'}"
  fi

  context_length="$SELECTED_CONTEXT_LENGTH"
  if (( context_length <= 0 )); then
    context_length="$(model_context_length "$model")"
  fi
  (( context_length > 0 )) || context_length=""

  route="$(ensure_routing_preset "$name" "$model" "$SELECTED_ENDPOINT")" || return
  switch_to "$name" "$route" "$model" "$SELECTED_ENDPOINT" "$SELECTED_ENDPOINT_NAME" "$context_length"
}

list_models() {
  local name="$1" query="${2:-}"
  has_catalog "$name" || { echo "provider '$name' has no model catalog" >&2; return 2; }
  ensure_credential "$name" || return
  fetch_models "$name" || return
  model_rows "$query" | awk -F '\t' '{printf "%-45s %s (%s context)\n", $1, $2, $3}'
}

list_endpoints() {
  local name="$1" model="$2" query="${3:-}"
  has_catalog "$name" || { echo "provider '$name' has no endpoint catalog" >&2; return 2; }
  ensure_credential "$name" || return
  # Only catalog model IDs may be interpolated into the authenticated request URL.
  fetch_models "$name" || return
  model_exists "$model" || { echo "unknown model '$model'; run: m models $name '$model'" >&2; return 2; }
  if model_routes_directly "$name" "$model"; then
    echo "$model selects a free model and endpoint automatically; there is no endpoint to pin"
    return 0
  fi
  fetch_endpoints "$name" "$model" || return
  endpoint_rows "$query" | awk -F '\t' '{
    discount = ($5 > 0 ? " (" $5 "% off)" : "")
    printf "%-24s %-20s $%s/$%s per 1M %s %s context%s\n", $1, $2, $3, $4, $6, $7, discount
  }'
}

provider_picker() {
  local cur sel i n=${#names} first=1 mark selected
  local -a labels
  cur="$(current)"
  sel=1
  for i in {1..$n}; do
    [[ "${names[i]}" == "$cur" ]] && sel=$i
    labels+=("$(label_of "${names[i]}")")
  done
  picker_enter
  {
    while true; do
      (( first )) || printf '\e[%dA' $(( n + 1 ))
      first=0
      for i in {1..$n}; do
        mark=" "
        [[ "${names[i]}" == "$cur" ]] && mark="o"
        if (( i == sel )); then picker_line "  ${mark} ${labels[i]}" hl; else picker_line "  ${mark} ${labels[i]}"; fi
      done
      picker_line "up/down to select, return to switch, q to quit" dim
      read_key
      case "$REPLY" in
        up|char:k)   (( sel > 1 )) && (( sel-- )) || true ;;
        down|char:j) (( sel < n )) && (( sel++ )) || true ;;
        char:q|esc)  break ;;
        enter)
          picker_leave   # nested pickers manage the terminal themselves
          selected="${names[sel]}"
          if [[ "$selected" == claude ]]; then
            switch_to claude
          elif has_catalog "$selected"; then
            catalog_switch "$selected"
          else
            ensure_credential "$selected" && switch_to "$selected"
          fi
          return ;;
      esac
    done
  } always {
    picker_leave
  }
}

cmd="${1:-}"
case "$cmd" in
  "")
    if [[ -t 0 && -t 1 ]]; then provider_picker; else print_status; fi ;;
  status)
    (( $# == 1 )) || { usage >&2; exit 2; }
    print_status ;;
  key)
    (( $# == 2 )) || { usage >&2; exit 2; }
    configure_key "$2" ;;
  models)
    (( $# >= 2 && $# <= 3 )) || { usage >&2; exit 2; }
    is_provider "$2" || { echo "unknown provider '$2'" >&2; exit 2; }
    list_models "$2" "${3:-}" ;;
  endpoints)
    (( $# >= 3 && $# <= 4 )) || { usage >&2; exit 2; }
    is_provider "$2" || { echo "unknown provider '$2'" >&2; exit 2; }
    list_endpoints "$2" "$3" "${4:-}" ;;
  help|-h|--help)
    usage ;;
  *)
    if ! is_provider "$cmd"; then
      echo "unknown provider or command '$cmd' — choices: ${names[*]} (or: m help)" >&2
      exit 2
    fi
    (( $# <= 3 )) || { usage >&2; exit 2; }
    if [[ "$cmd" == claude ]]; then
      (( $# == 1 )) || { usage >&2; exit 2; }
      switch_to claude
    elif has_catalog "$cmd"; then
      catalog_switch "$cmd" "${2:-}" "${3:-}"
    else
      (( $# == 1 )) || { echo "provider '$cmd' does not accept a model or endpoint" >&2; exit 2; }
      ensure_credential "$cmd" && switch_to "$cmd"
    fi ;;
esac
