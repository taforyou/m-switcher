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

set -e
SETTINGS="${M_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="${M_CLAUDE_JSON:-$HOME/.claude.json}"
PROV="${M_PROVIDERS:-$HOME/.claude/providers.json}"

[[ -f "$SETTINGS" ]] || { echo "missing $SETTINGS" >&2; exit 1; }
[[ -f "$PROV"     ]] || { echo "missing $PROV" >&2; exit 1; }

names=(claude ${(f)"$(jq -r 'keys_unsorted[]' "$PROV")"})
HTTP_DATA=""
HTTP_STATUS=""
MODEL_DATA=""
ENDPOINT_DATA=""
SELECTED_MODEL=""
SELECTED_ENDPOINT=""
SELECTED_ENDPOINT_NAME=""
SELECTED_CONTEXT_LENGTH=""

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

# Makes an authenticated JSON request without putting the API key in curl's
# process arguments. Results are returned through HTTP_STATUS and HTTP_DATA.
http_request() {
  local method="$1" url="$2" token="$3" payload="${4:-}"
  local prefix="${TMPDIR:-/tmp}/m-switcher-http"
  local header_file response_file payload_file=""
  local -a args
  header_file="$(mktemp "${prefix}.header.XXXXXX")"
  response_file="$(mktemp "${prefix}.response.XXXXXX")"
  chmod 600 "$header_file" "$response_file"
  if [[ -n "$payload" ]]; then
    payload_file="$(mktemp "${prefix}.payload.XXXXXX")"
    chmod 600 "$payload_file"
  fi
  {
    printf 'Authorization: Bearer %s\n' "$token" > "$header_file"
    [[ -n "$payload_file" ]] && printf '%s' "$payload" > "$payload_file"
    args=(-sS --connect-timeout 10 --max-time 30 -o "$response_file" -w '%{http_code}'
          -X "$method" -H "@$header_file")
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

validate_key() {
  local name="$1" token="$2" url
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
  if ! jq --arg n "$name" --arg key "$key_env" --arg value "$token" \
       '.[$n].env[$key] = $value' "$PROV" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  cp "$PROV" "$PROV.bak"
  mv "$tmp" "$PROV"
  echo "saved and validated API key for $(label_of "$name")"
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
  local name="$1" token url special
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
  MODEL_DATA="$(printf '%s' "$HTTP_DATA" | jq -c --argjson special "$special" '
    .data as $models
    | .data = ($special + [
        $models[] | .id as $id | select(($special | any(.id == $id)) | not)
      ])
  ')"
}

model_rows() {
  local query="${1:l}"
  printf '%s' "$MODEL_DATA" | jq -r --arg q "$query" '
    def clean: gsub("[[:cntrl:]]"; " ");
    def lower: ascii_downcase;
    def rank($q):
      if $q == "" then 0
      elif ((.id // "" | lower) | startswith($q))
        or ((.name // "" | lower) | startswith($q)) then 0
      elif ((.id // "" | lower) | contains($q))
        or ((.name // "" | lower) | contains($q)) then 1
      else 2 end;
    .data
    | map(. + {"_m_rank": rank($q)})
    | map(select(._m_rank < 2))
    | (if $q == "" then . else sort_by(._m_rank) end)
    | .[]
    | [
        .id,
        ((.name // .id) | clean),
        (if (.context_length // 0) >= 1000000
         then (((.context_length / 1000000 * 10) | floor) / 10 | tostring) + "M"
         else (((.context_length // 0) / 1000 | floor | tostring) + "k") end)
      ]
    | @tsv
  '
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

model_picker() {
  local query="${1:-}" sel=1 page_size=10 first=1 active_model
  local key rest row id tail display context mark text i total start
  local -a rows
  SELECTED_MODEL=""
  active_model="$(current_model 2>/dev/null || true)"
  printf '\e[?25l'
  {
    while true; do
      rows=(${(f)"$(model_rows "$query")"})
      total=${#rows}
      (( total == 0 )) && sel=1
      (( total > 0 && sel > total )) && sel=$total
      (( sel < 1 )) && sel=1
      start=$(( total == 0 ? 0 : ((sel - 1) / page_size) * page_size ))

      (( first )) || printf '\e[13A'
      first=0
      printf '\e[KOpenRouter models (%d matches)\n' "$total"
      printf '\e[KSearch: %-60.60s\n' "$query"
      for i in {1..$page_size}; do
        local index=$(( start + i ))
        if (( index <= total )); then
          row="${rows[index]}"
          id="${row%%$'\t'*}"
          tail="${row#*$'\t'}"
          display="${tail%%$'\t'*}"
          context="${tail##*$'\t'}"
          mark=" "
          [[ "$id" == "$active_model" ]] && mark="o"
          text="${display} — ${id} (${context})"
          if (( index == sel )); then
            printf '\e[K  \e[36m%s %-70.70s\e[0m\n' "$mark" "$text"
          else
            printf '\e[K  %s %-70.70s\n' "$mark" "$text"
          fi
        else
          printf '\e[K\n'
        fi
      done
      printf '\e[K\e[2mtype to search, backspace to erase, arrows to move, return to select, esc to cancel\e[0m\n'

      read -sk1 key || { key=$'\e'; }
      case "$key" in
        $'\e')
          rest=""
          read -sk2 -t 0.05 rest 2>/dev/null || true
          case "$rest" in
            '[A') (( sel > 1 )) && (( sel-- )) || true ;;
            '[B') (( sel < total )) && (( sel++ )) || true ;;
            *) return 130 ;;
          esac ;;
        $'\x7f'|$'\b')
          if (( ${#query} > 0 )); then query="${query[1,-2]}"; sel=1; fi ;;
        $'\n'|$'\r')
          if (( total > 0 )); then
            row="${rows[sel]}"
            SELECTED_MODEL="${row%%$'\t'*}"
            return 0
          fi ;;
        *)
          if [[ "$key" == [[:print:]] && ${#query} -lt 60 ]]; then
            query+="$key"
            sel=1
          fi ;;
      esac
    done
  } always {
    printf '\e[?25h'
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
  local query="${1:-}" sel=1 page_size=10 first=1
  local key rest row tag tail display input_price output_price discount quant context_length mark text i total start
  local -a rows
  SELECTED_ENDPOINT=""
  SELECTED_ENDPOINT_NAME=""
  SELECTED_CONTEXT_LENGTH=""
  printf '\e[?25l'
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
      printf '\e[KHosting endpoints — cheapest is selected by default (%d matches)\n' "$total"
      printf '\e[KSearch: %-60.60s\n' "$query"
      for i in {1..$page_size}; do
        local index=$(( start + i ))
        if (( index <= total )); then
          row="${rows[index]}"
          tag="${row%%$'\t'*}"; tail="${row#*$'\t'}"
          display="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          input_price="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          output_price="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          discount="${tail%%$'\t'*}"; tail="${tail#*$'\t'}"
          quant="${tail%%$'\t'*}"; context_length="${tail##*$'\t'}"
          mark=" "
          (( index == 1 && start == 0 )) && mark="*"
          text="${display} [${tag}] \$${input_price}/\$${output_price}/M ${quant}"
          (( discount > 0 )) && text+=" (${discount}% off)"
          if (( index == sel )); then
            printf '\e[K  \e[36m%s %-72.72s\e[0m\n' "$mark" "$text"
          else
            printf '\e[K  %s %-72.72s\n' "$mark" "$text"
          fi
        else
          printf '\e[K\n'
        fi
      done
      printf '\e[K\e[2m* cheapest; type to search, arrows to move, return to pin endpoint, esc to cancel\e[0m\n'

      read -sk1 key || { key=$'\e'; }
      case "$key" in
        $'\e')
          rest=""
          read -sk2 -t 0.05 rest 2>/dev/null || true
          case "$rest" in
            '[A') (( sel > 1 )) && (( sel-- )) || true ;;
            '[B') (( sel < total )) && (( sel++ )) || true ;;
            *) return 130 ;;
          esac ;;
        $'\x7f'|$'\b')
          if (( ${#query} > 0 )); then query="${query[1,-2]}"; sel=1; fi ;;
        $'\n'|$'\r')
          if (( total > 0 )); then
            row="${rows[sel]}"
            SELECTED_ENDPOINT="${row%%$'\t'*}"
            tail="${row#*$'\t'}"
            SELECTED_ENDPOINT_NAME="${tail%%$'\t'*}"
            SELECTED_CONTEXT_LENGTH="${tail##*$'\t'}"
            return 0
          fi ;;
        *)
          if [[ "$key" == [[:print:]] && ${#query} -lt 60 ]]; then
            query+="$key"
            sel=1
          fi ;;
      esac
    done
  } always {
    printf '\e[?25h'
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
  local name="$1" model="$2" endpoint="$3" token base slug url payload
  token="$(credential_of "$name")"
  base="$(jq -r --arg n "$name" '.[$n].modelCatalog.presetsUrl // ""' "$PROV")"
  [[ -n "$base" ]] || { echo "provider '$name' does not support exact endpoint routing" >&2; return 2; }
  slug="$(preset_slug "$model" "$endpoint")"
  url="${base%/}/$slug"

  # Reuse an identical preset. This avoids creating a new preset version each
  # time the same model/endpoint route is selected.
  http_request GET "$url" "$token" || return 1
  if [[ "$HTTP_STATUS" == 200 ]] && printf '%s' "$HTTP_DATA" | jq -e \
       --arg model "$model" --arg endpoint "$endpoint" '
       .data.designated_version.config as $c
       | $c.model == $model
         and $c.provider.only == [$endpoint]
         and $c.provider.allow_fallbacks == false
     ' >/dev/null 2>&1; then
    printf '@preset/%s\n' "$slug"
    return 0
  elif [[ "$HTTP_STATUS" != 200 && "$HTTP_STATUS" != 404 ]]; then
    print_api_error "unable to inspect OpenRouter routing preset"
    return 1
  fi

  payload="$(jq -nc --arg model "$model" --arg endpoint "$endpoint" '{
    model: $model,
    messages: [{role: "user", content: "m-switcher routing preset"}],
    provider: {
      only: [$endpoint],
      allow_fallbacks: false
    }
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

  local tmp
  tmp="$(mktemp "$SETTINGS.XXXXXX")"
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
    rm -f "$tmp"
    return 1
  fi
  cp "$SETTINGS" "$SETTINGS.bak"
  mv "$tmp" "$SETTINGS"

  # Provider-declared ~/.claude.json flags (e.g. Kimi onboarding flags).
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
    model_picker "$model_arg" || return
    model="$SELECTED_MODEL"
  elif [[ -n "$model_arg" ]]; then
    echo "unknown model '$model_arg'; run: m models $name '$model_arg'" >&2
    return 2
  elif [[ -t 0 && -t 1 ]]; then
    model_picker || return
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
  ensure_credential "$name" || return
  has_catalog "$name" || { echo "provider '$name' has no model catalog" >&2; return 2; }
  fetch_models "$name" || return
  model_rows "$query" | awk -F '\t' '{printf "%-45s %s (%s context)\n", $1, $2, $3}'
}

list_endpoints() {
  local name="$1" model="$2" query="${3:-}"
  ensure_credential "$name" || return
  has_catalog "$name" || { echo "provider '$name' has no endpoint catalog" >&2; return 2; }
  if model_routes_directly "$name" "$model"; then
    echo "$model selects a free model and endpoint automatically; there is no endpoint to pin"
    return 0
  fi
  fetch_endpoints "$name" "$model" || return
  endpoint_rows "$query" | awk -F '\t' '{
    discount = ($5 > 0 ? " (" $5 "% off)" : "")
    printf "%-24s %-20s $%s/$%s per 1M %s%s\n", $1, $2, $3, $4, $6, discount
  }'
}

provider_picker() {
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
      read -sk1 key || { key="q"; }
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
          local selected="${names[sel]}"
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
    printf '\e[?25h'
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
