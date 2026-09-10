#!/bin/zsh
set -e

ROOT="${0:A:h:h}"
TEST_TMP="$(mktemp -d)"
SETTINGS="$TEST_TMP/settings.json"
PROVIDERS="$TEST_TMP/providers.json"
CLAUDE_JSON="$TEST_TMP/claude.json"
OUTPUT="$TEST_TMP/output"
M_TEST_LOG="$TEST_TMP/request.json"
ARGV_LOG="$TEST_TMP/argv.log"

# The temp dir holds fake keys only; keep it for inspection with M_TEST_KEEP=1.
trap '[[ -n "${M_TEST_KEEP:-}" ]] || rm -rf "$TEST_TMP"' EXIT

export PATH="$ROOT/tests/bin:$PATH"
export M_TEST_FIXTURES="$ROOT/tests/fixtures"
export M_TEST_LOG
export M_SETTINGS="$SETTINGS"
export M_PROVIDERS="$PROVIDERS"
export M_CLAUDE_JSON="$CLAUDE_JSON"

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_jq() {
  jq -e "$1" "$2" >/dev/null || fail "$3"
}

# Every m run traces the argv of the jq/curl it spawns into $ARGV_LOG; the
# suite's own jq calls are not traced, so a key found there came from m.
m() {
  M_TEST_ARGV_LOG="$ARGV_LOG" "$ROOT/m" "$@"
}

# Runs m expecting success; stdout goes to $OUTPUT, stderr to $OUTPUT.err.
run() {
  m "$@" > "$OUTPUT" 2> "$OUTPUT.err" \
    || fail "m $* failed (exit $?): $(cat "$OUTPUT.err" "$OUTPUT")"
}

# Runs m expecting a specific non-zero exit code; stdout+stderr go to $OUTPUT.
expect_rc() {
  local want="$1" rc=0
  shift
  m "$@" > "$OUTPUT" 2>&1 || rc=$?
  (( rc == want )) || fail "m $* exited $rc, expected $want: $(cat "$OUTPUT")"
}

mode_of() {
  local listing
  listing="$(ls -ld "$1")"
  echo "${listing[1,10]}"
}

assert_private() {
  [[ "$(mode_of "$1")" == "-rw-------" ]] || fail "$2 ($1 is $(mode_of "$1"))"
}

snapshot() {
  jq -S . "$1"
}

# --- fixtures ---------------------------------------------------------------
# settings.json and providers.json start out 644, as Claude Code and a
# hand-made copy leave them; stale 644 backups mimic earlier m versions.
printf '%s\n' '{"env":{"KEEP_ME":"yes"},"permissions":{"allow":["Read"]},"modelOverrides":{"claude-opus-4-6":"user/opus-route"}}' > "$SETTINGS"
cp "$ROOT/providers.example.json" "$PROVIDERS"
chmod 644 "$SETTINGS" "$PROVIDERS"
printf '{}\n' > "$SETTINGS.bak"
printf '{}\n' > "$PROVIDERS.bak"
chmod 644 "$SETTINGS.bak" "$PROVIDERS.bak"

# --- guards before any key is configured ------------------------------------
# A placeholder key is refused with exit 3 and nothing is written.
before="$(snapshot "$SETTINGS")"
expect_rc 3 zai
grep -q 'refusing: API key' "$OUTPUT" || fail "placeholder guard did not explain itself"
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "placeholder guard modified settings"
[[ "$(cat "$SETTINGS.bak")" == "{}" ]] || fail "placeholder guard wrote a backup"

# Providers without a catalog say so before asking for a key.
expect_rc 2 models kimi
grep -q 'no model catalog' "$OUTPUT" || fail "m models kimi did not report the missing catalog"
if grep -q 'refusing' "$OUTPUT"; then fail "m models kimi demanded a key before checking for a catalog"; fi
expect_rc 2 models claude
grep -q 'no model catalog' "$OUTPUT" || fail "m models claude did not report the missing catalog"

# CLI usage errors exit 2. (zai now takes a model argument; kimi is still a
# plain provider that accepts none.)
expect_rc 2 bogus
expect_rc 2 kimi extra
expect_rc 2 status extra

# --- m key ------------------------------------------------------------------
# A rejected key is not saved.
printf '%s\n' 'sk-bad' | expect_rc 3 key openrouter
grep -q 'HTTP 401' "$OUTPUT" || fail "rejected key did not report the API error"
assert_jq '.openrouter.env.ANTHROPIC_AUTH_TOKEN | startswith("<")' "$PROVIDERS" \
  "rejected key was saved"

# The key command reads from stdin without echoing it, validates it, and saves
# only after validation succeeds. providers.json and its backup end up private
# even though both started out 644.
printf '%s\n' 'sk-or-test' | run key openrouter
grep -q '^saved and validated API key for OpenRouter' "$OUTPUT" || fail "key save message wrong: $(cat "$OUTPUT")"
assert_jq '.openrouter.env.ANTHROPIC_AUTH_TOKEN == "sk-or-test"' "$PROVIDERS" \
  "OpenRouter key was not saved"
assert_private "$PROVIDERS" "providers.json is not private after m key"
assert_private "$PROVIDERS.bak" "providers.json.bak is not private after m key"

# Providers without a validationUrl are saved but not reported as validated.
printf '%s\n' 'zai-key' | run key zai
grep -q '^saved API key for Z.ai (GLM) (not validated' "$OUTPUT" || fail "unvalidated save was misreported: $(cat "$OUTPUT")"
printf '%s\n' 'kimi-key' | run key kimi
grep -q '(not validated' "$OUTPUT" || fail "unvalidated Kimi save was misreported"
assert_jq '.zai.env.ANTHROPIC_AUTH_TOKEN == "zai-key" and .kimi.env.ANTHROPIC_API_KEY == "kimi-key"' "$PROVIDERS" \
  "plain provider keys were not saved"

# --- catalog listings -------------------------------------------------------
# Prefix search should put Q-prefixed models in the result and exclude models
# that do not match the prefix/substring.
run models openrouter Q
grep -q '^qwen/qwen3-coder' "$OUTPUT" || fail "Q search did not find Qwen"
if grep -q 'z-ai/glm-5.2' "$OUTPUT"; then fail "Q search included an unrelated model"; fi
run models openrouter free
grep -q '^openrouter/free' "$OUTPUT" || fail "automatic free router was not listed"

# The model picker exposes All/Discounted/Free scopes, applies each scope's
# ordering, loads promotions only on demand, and preserves price color.
run_picker() {
  local keys="$1"
  local picker_settings="$TEST_TMP/picker-settings.json"
  local picker_claude_json="$TEST_TMP/picker-claude.json"
  local picker_log="$TEST_TMP/picker-request.json"
  local -a script_args
  printf '{}\n' > "$picker_settings"
  printf '{}\n' > "$picker_claude_json"
  if [[ "$(uname -s)" == Darwin ]]; then
    script_args=(-q -e /dev/null "$ROOT/m" openrouter)
  else
    # util-linux script takes the child command through -c.
    script_args=(-q -e -c '"$M_TEST_PICKER_COMMAND" openrouter' /dev/null)
  fi
  if ! printf '%b' "$keys" | env \
      M_SETTINGS="$picker_settings" \
      M_CLAUDE_JSON="$picker_claude_json" \
      M_TEST_LOG="$picker_log" \
      M_TEST_ARGV_LOG="$ARGV_LOG" \
      M_TEST_PICKER_COMMAND="$ROOT/m" \
      script "${script_args[@]}" > "$OUTPUT" 2>&1; then
    fail "interactive model picker failed: $(cat "$OUTPUT")"
  fi
}

run_picker '\033[C\033[C\033[B\r'
grep -Fq 'Models: [All]  Discounted  Free' "$OUTPUT" || fail "model picker did not show all three scopes"
grep -Fq '38;5;46m' "$OUTPUT" || fail "free model was not green"
grep -Fq '38;5;196m' "$OUTPUT" || fail "expensive model was not red"
grep -Fq '$5/$25/M' "$OUTPUT" || fail "model picker did not show live per-token prices"
all_discount_row="$(grep -m1 -F 'Z.ai: GLM 5.2' "$OUTPUT")"
[[ "$all_discount_row" == *'[77%] Z.ai: GLM 5.2'* ]] \
  || fail "All scope did not prefix a promoted model with its discount"
[[ "$all_discount_row" == *$'\033[9m$1.4/$4.4\033[29m → $0.3248/$1.0208'* ]] \
  || fail "All scope did not show the struck list price and promotional price"
grep -Fq 'GET https://openrouter.ai/collections/discounted-models' "$TEST_TMP/picker-request.json.requests" \
  || fail "model picker did not load promotions for the All scope"
all_red_line="$(grep -n -m1 -F 'OpenAI: GPT Test' "$OUTPUT" | cut -d: -f1)"
all_mid_line="$(grep -n -m1 -F 'Z.ai: GLM 5.2' "$OUTPUT" | cut -d: -f1)"
all_cheap_line="$(grep -n -m1 -F 'Qwen: Qwen3 Coder' "$OUTPUT" | cut -d: -f1)"
all_free_line="$(grep -n -m1 -F 'OpenRouter: Free Models Router' "$OUTPUT" | cut -d: -f1)"
(( all_red_line < all_mid_line && all_mid_line < all_cheap_line && all_cheap_line < all_free_line )) \
  || fail "All scope was not sorted from most expensive to free"
free_large_line="$(grep -n -F 'Google: Gemma Test (free)' "$OUTPUT" | tail -n 1 | cut -d: -f1)"
free_small_line="$(grep -n -F 'OpenRouter: Free Models Router' "$OUTPUT" | tail -n 1 | cut -d: -f1)"
(( free_large_line < free_small_line )) || fail "Free scope was not sorted by largest context first"

run_picker '\033[C\033[B\r\r'
grep -Fq 'Models: All  [Discounted]  Free — 2 matches' "$OUTPUT" \
  || fail "right arrow did not open the discounted scope"
grep -Fq 'GET https://openrouter.ai/collections/discounted-models' "$TEST_TMP/picker-request.json.requests" \
  || fail "model picker did not load OpenRouter's live discount collection"
grep -Fq '[90%] Qwen: Qwen3 Coder' "$OUTPUT" \
  || fail "discounted scope did not put the promotion before the model name"
grep -Fq '[77%] Z.ai: GLM 5.2' "$OUTPUT" \
  || fail "discounted scope did not round and prefix the promotion"
grep -Fq 'prices: input / output per 1M tokens' "$OUTPUT" \
  || fail "discounted scope did not label its price order and unit"
grep -Fq $'\033[9m$1.4/$4.4\033[29m → $0.3248/$1.0208' "$OUTPUT" \
  || fail "discounted scope did not strike the list price and show the promotional price"
grep -Fq '* [77%] StreamLake [streamlake/fp8]' "$OUTPUT" \
  || fail "endpoint picker did not prefix the provider name with its discount"
discount_high_line="$(grep -n -F '[90%] Qwen: Qwen3 Coder' "$OUTPUT" | tail -n 1 | cut -d: -f1)"
discount_low_line="$(grep -n -F '[77%] Z.ai: GLM 5.2' "$OUTPUT" | tail -n 1 | cut -d: -f1)"
(( discount_high_line < discount_low_line )) \
  || fail "Discounted scope was not sorted by largest percentage reduction"
assert_jq '.env.M_SWITCHER_MODEL == "z-ai/glm-5.2"' "$TEST_TMP/picker-settings.json" \
  "discounted scope did not select its matching model"

run_picker '\033[C\033[C\033[B\r'
grep -Fq 'Models: All  Discounted  [Free] — 2 matches' "$OUTPUT" \
  || fail "right arrow did not open the free scope"
assert_jq '.env.M_SWITCHER_MODEL == "openrouter/free"' "$TEST_TMP/picker-settings.json" \
  "free scope did not select the automatic free router"

# Batch-API variants are hidden from the catalog and cannot be pinned.
run models openrouter batch
if grep -q ':batch' "$OUTPUT"; then fail ":batch variant was listed"; fi
expect_rc 2 openrouter anthropic/claude-test:batch
grep -q "unknown model 'anthropic/claude-test:batch'" "$OUTPUT" || fail ":batch variant was accepted"

# Endpoints are healthy and tool-capable only, cheapest first, with the live
# discount rounded in the same style as OpenRouter's UI and the context shown.
run endpoints openrouter z-ai/glm-5.2
first_endpoint="$(sed -n '1p' "$OUTPUT")"
[[ "$first_endpoint" == streamlake/fp8* ]] || fail "cheapest endpoint was not first"
[[ "$first_endpoint" == *'[77%] StreamLake'* ]] || fail "discount was not prefixed to the provider name"
[[ "$first_endpoint" == *'1M context'* ]] || fail "endpoint context was not displayed"
if grep -q '^notools' "$OUTPUT"; then fail "endpoint without tools was listed"; fi
if grep -q '^together' "$OUTPUT"; then fail "unhealthy endpoint was listed"; fi
grep -q '^fireworks/fast' "$OUTPUT" || fail "sibling endpoint missing from the list"

# m endpoints only ever puts catalog model IDs into the request URL.
expect_rc 2 endpoints openrouter '../../key'
grep -q "unknown model" "$OUTPUT" || fail "m endpoints accepted a non-catalog model"
if grep -q 'key/endpoints' "$M_TEST_LOG.requests"; then fail "m endpoints requested a URL built from an unvalidated argument"; fi

# Catalog failures leave settings untouched.
before="$(snapshot "$SETTINGS")"
rc=0
M_TEST_FAIL_MODELS=1 m openrouter z-ai/glm-5.2 > "$OUTPUT" 2>&1 || rc=$?
(( rc == 1 )) || fail "catalog failure exited $rc, expected 1"
grep -q 'server exploded (HTTP 500)' "$OUTPUT" || fail "catalog failure was not reported"
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "catalog failure modified settings"

# --- non-interactive OpenRouter switch --------------------------------------
# A non-interactive model switch chooses the current cheapest healthy endpoint,
# creates an exact-routing preset, and assigns it to every Claude Code model
# role. Both settings files become private even though they started out 644.
run openrouter z-ai/glm-5.2
grep -q '^switched to OpenRouter' "$OUTPUT" || fail "switch confirmation missing"
assert_jq '.env.ANTHROPIC_BASE_URL == "https://openrouter.ai/api"' "$SETTINGS" \
  "OpenRouter base URL was not installed"
assert_jq '.env.ANTHROPIC_API_KEY == ""' "$SETTINGS" \
  "Anthropic API key was not explicitly blanked"
assert_jq '.env.ANTHROPIC_MODEL == "@preset/m-switcher-z-ai-glm-5-2-streamlake-fp8-527906733[1m]"' "$SETTINGS" \
  "routing preset was not selected (or its deterministic slug changed)"
for role in $(jq -r '.openrouter.modelCatalog.modelEnv[]' "$PROVIDERS"); do
  jq -e --arg k "$role" '.env[$k] == .env.ANTHROPIC_MODEL' "$SETTINGS" >/dev/null \
    || fail "model role $role does not use the selected route"
done
[[ "$(jq -r '.openrouter.modelCatalog.modelEnv | length' "$PROVIDERS")" == 6 ]] \
  || fail "modelEnv no longer lists all six Claude Code model roles"
assert_jq '.env.ANTHROPIC_DEFAULT_FABLE_MODEL == .env.ANTHROPIC_MODEL
           and .env.CLAUDE_CODE_SUBAGENT_MODEL == .env.ANTHROPIC_MODEL' "$SETTINGS" \
  "not every Claude Code model role uses the selected route"
# An agent definition or per-spawn override naming another model must not pull
# a subagent off the route: Claude Code 2.1.251+ lets those win over
# CLAUDE_CODE_SUBAGENT_MODEL unless the force flag is set.
assert_jq '.env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE == "1"' "$SETTINGS" \
  "subagents are not forced onto the selected route"
assert_jq '.env.M_SWITCHER_MODEL == "z-ai/glm-5.2"
           and .env.M_SWITCHER_ENDPOINT == "streamlake/fp8"
           and .env.M_SWITCHER_ENDPOINT_NAME == "StreamLake"
           and .env.M_SWITCHER_CONTEXT_LENGTH == "1024000"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "1024000"
           and .env.M_SWITCHER_MODEL_OVERRIDE_KEY == "claude-sonnet-4-6"
           and (.modelOverrides[.env.M_SWITCHER_MODEL_OVERRIDE_KEY]
                == (.env.ANTHROPIC_MODEL | sub("\\[1m\\]$"; "")))' "$SETTINGS" \
  "route metadata was not saved"
assert_jq '.env.KEEP_ME == "yes" and .permissions.allow == ["Read"]
           and .modelOverrides["claude-opus-4-6"] == "user/opus-route"' "$SETTINGS" \
  "unrelated settings were changed"
assert_jq '.model == "z-ai/glm-5.2"
           and .provider.only == ["streamlake/fp8"]
           and .provider.allow_fallbacks == false
           and (.provider | has("ignore") | not)' "$M_TEST_LOG" \
  "preset does not pin the exact endpoint"
assert_private "$SETTINGS" "settings.json is not private after a switch"
assert_private "$SETTINGS.bak" "settings.json.bak is not private after a switch"
assert_jq '.env == {"KEEP_ME":"yes"}' "$SETTINGS.bak" "settings.json.bak does not hold the previous settings"

run status
grep -q '^active: OpenRouter' "$OUTPUT" || fail "status did not name the active provider"
grep -q 'model: z-ai/glm-5.2' "$OUTPUT" || fail "status omitted selected model"
grep -q 'endpoint: StreamLake' "$OUTPUT" || fail "status omitted selected endpoint"
grep -q 'context: 1024000 tokens' "$OUTPUT" || fail "status omitted endpoint context"

# Selecting the same route again reuses the existing preset instead of
# creating a new version.
rm -f "$M_TEST_LOG"
run openrouter z-ai/glm-5.2
[[ ! -f "$M_TEST_LOG" ]] || fail "identical preset was re-created"
assert_jq '.env.ANTHROPIC_MODEL == "@preset/m-switcher-z-ai-glm-5-2-streamlake-fp8-527906733[1m]"' "$SETTINGS" \
  "route changed on an identical switch"

# An explicit endpoint tag overrides the cheapest default; a 512K window gets
# neither the [1m] suffix nor a recognition mapping.
run openrouter z-ai/glm-5.2 regularcloud/fp8
assert_jq '.env.M_SWITCHER_ENDPOINT == "regularcloud/fp8"
           and .env.M_SWITCHER_ENDPOINT_NAME == "RegularCloud"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "524288"
           and (.env.ANTHROPIC_MODEL | endswith("[1m]") | not)
           and (.modelOverrides | has("claude-sonnet-4-6") | not)' "$SETTINGS" \
  "explicit endpoint selection did not override the cheapest endpoint"

# An endpoint advertising exactly 1,000,000 tokens is a genuine 1M route.
run openrouter z-ai/glm-5.2 venice/fp8
assert_jq '(.env.ANTHROPIC_MODEL | endswith("[1m]"))
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "1000000"
           and .modelOverrides["claude-sonnet-4-6"] == (.env.ANTHROPIC_MODEL | sub("\\[1m\\]$"; ""))' "$SETTINGS" \
  "exact 1M endpoint was not treated as a 1M route"

# A bare provider tag is narrowed to that exact endpoint by ignoring its
# suffixed siblings, and the narrowed preset is reused on the next switch.
run openrouter z-ai/glm-5.2 fireworks
assert_jq '.provider.only == ["fireworks"]
           and .provider.ignore == ["fireworks/fast"]
           and .provider.allow_fallbacks == false' "$M_TEST_LOG" \
  "bare provider tag was not narrowed with provider.ignore"
rm -f "$M_TEST_LOG"
run openrouter z-ai/glm-5.2 fireworks
[[ ! -f "$M_TEST_LOG" ]] || fail "narrowed preset was re-created"

# Unavailable, tool-less, unhealthy or unknown endpoints are refused without
# touching settings.
before="$(snapshot "$SETTINGS")"
expect_rc 2 openrouter z-ai/glm-5.2 notools
expect_rc 2 openrouter z-ai/glm-5.2 together
expect_rc 2 openrouter z-ai/glm-5.2 nope/tag
grep -q 'unavailable or lacks tool support' "$OUTPUT" || fail "unknown endpoint was not explained"
expect_rc 2 openrouter nonexistent/model
grep -q "unknown model 'nonexistent/model'" "$OUTPUT" || fail "unknown model was not explained"
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "a refused endpoint/model modified settings"

# The automatic free router is a direct model route: it lets OpenRouter choose
# a tool-capable free model per request and therefore skips endpoint pinning.
run openrouter openrouter/free
assert_jq '.env.ANTHROPIC_MODEL == "openrouter/free"
           and .env.ANTHROPIC_DEFAULT_OPUS_MODEL == "openrouter/free"
           and .env.ANTHROPIC_DEFAULT_FABLE_MODEL == "openrouter/free"
           and .env.M_SWITCHER_MODEL == "openrouter/free"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "200000"
           and .modelOverrides["claude-sonnet-4-6"] == "openrouter/free"
           and (.env | has("M_SWITCHER_ENDPOINT") | not)' "$SETTINGS" \
  "automatic free router was not configured as a direct route"
run status
grep -q 'model: openrouter/free' "$OUTPUT" || fail "status omitted free router"
if grep -q 'endpoint:' "$OUTPUT"; then fail "free router incorrectly reported a pinned endpoint"; fi
expect_rc 2 openrouter openrouter/free streamlake/fp8
grep -q 'does not accept an endpoint' "$OUTPUT" || fail "direct route accepted an endpoint"

# --- static catalog provider (Z.ai) ------------------------------------------
# The bundled Z.ai entry ships its model list inside providers.json: models
# are listed, searched, and routed offline — none of this section may touch
# the network.
rm -f "$M_TEST_LOG" "$M_TEST_LOG.requests" "$M_TEST_LOG.headers"
run models zai
grep -q '^glm-5.3 ' "$OUTPUT" || fail "static catalog did not list glm-5.3"
grep -q '^glm-5.3-flash ' "$OUTPUT" || fail "static catalog did not list glm-5.3-flash"
grep -q '^glm-5.2 ' "$OUTPUT" || fail "static catalog did not list glm-5.2"
grep -q '^glm-5-turbo ' "$OUTPUT" || fail "static catalog did not list glm-5-turbo"
grep -q '^glm-4.7 ' "$OUTPUT" || fail "static catalog did not list glm-4.7"
[[ "$(grep -c '^glm-' "$OUTPUT")" == 5 ]] || fail "static catalog listed unexpected models"
grep -q '1M context' "$OUTPUT" || fail "static catalog did not show context windows"
run models zai flash
[[ "$(grep -c '^glm-' "$OUTPUT")" == 1 ]] || fail "static catalog search did not narrow to the flash model"
before="$(snapshot "$SETTINGS")"
expect_rc 2 endpoints zai glm-5.3
grep -q 'does not support endpoint selection' "$OUTPUT" || fail "static catalog provider claimed endpoint support"
expect_rc 2 zai nonexistent/model
grep -q "unknown model 'nonexistent/model'" "$OUTPUT" || fail "unknown static model was accepted"
expect_rc 2 zai glm-5.3 streamlake/fp8
grep -q 'does not support endpoint selection' "$OUTPUT" || fail "static catalog provider accepted an endpoint argument"
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "a refused static route modified settings"

# Selecting a 1M model routes every model role with the [1m] suffix, forces
# subagents onto it, and configures both context variables to the model's
# real 1M window.
run zai glm-5.3
assert_jq '.env.ANTHROPIC_BASE_URL == "https://api.z.ai/api/anthropic"
           and .env.ANTHROPIC_AUTH_TOKEN == "zai-key"
           and .env.ANTHROPIC_MODEL == "glm-5.3[1m]"
           and .env.ANTHROPIC_DEFAULT_HAIKU_MODEL == "glm-5.3[1m]"
           and .env.CLAUDE_CODE_SUBAGENT_MODEL == "glm-5.3[1m]"
           and .env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE == "1"
           and .env.M_SWITCHER_MODEL == "glm-5.3"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "1000000"
           and .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW == "1000000"
           and .modelOverrides["claude-sonnet-4-6"] == "glm-5.3"
           and (.env | has("M_SWITCHER_ENDPOINT") | not)' "$SETTINGS" \
  "1M Z.ai model was not routed with its real window"
for role in $(jq -r '.zai.modelCatalog.modelEnv[]' "$PROVIDERS"); do
  jq -e --arg k "$role" '.env[$k] == "glm-5.3[1m]"' "$SETTINGS" >/dev/null \
    || fail "Z.ai model role $role does not use the selected model"
done
assert_jq '.env.KEEP_ME == "yes" and .permissions.allow == ["Read"]
           and .modelOverrides["claude-opus-4-6"] == "user/opus-route"' "$SETTINGS" \
  "Z.ai model switch changed unrelated settings"
run status
grep -q '^active: Z.ai (GLM) — model: glm-5.3 — context: 1000000 tokens' "$OUTPUT" \
  || fail "status did not report the Z.ai route: $(cat "$OUTPUT")"
if grep -q 'endpoint:' "$OUTPUT"; then fail "Z.ai status invented an endpoint"; fi

# A cheaper 1M pick replaces every role the static env block seeds with
# another model, so nothing in the session bills against the dearer default.
run zai glm-5.3-flash
for role in $(jq -r '.zai.modelCatalog.modelEnv[]' "$PROVIDERS"); do
  jq -e --arg k "$role" '.env[$k] == "glm-5.3-flash[1m]"' "$SETTINGS" >/dev/null \
    || fail "Z.ai model role $role still names another model after picking flash"
done
assert_jq '.env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE == "1"
           and .env.M_SWITCHER_MODEL == "glm-5.3-flash"
           and .modelOverrides["claude-sonnet-4-6"] == "glm-5.3-flash"' "$SETTINGS" \
  "flash selection did not pin subagents"
if jq -r '.env | to_entries[] | select(.key != "M_SWITCHER_MODEL") | .value' "$SETTINGS" \
     | grep -qx 'glm-5.3\(\[1m\]\)\?'; then
  fail "a model role still points at glm-5.3 after picking glm-5.3-flash"
fi

# A 200K model drops the [1m] suffix and shrinks both window variables.
run zai glm-4.7
assert_jq '.env.ANTHROPIC_MODEL == "glm-4.7"
           and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == "glm-4.7"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "200000"
           and .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW == "200000"
           and .modelOverrides["claude-sonnet-4-6"] == "glm-4.7"' "$SETTINGS" \
  "200K Z.ai model was routed with the wrong window"

# Everything in this section ran offline.
[[ ! -e "$M_TEST_LOG" && ! -e "$M_TEST_LOG.requests" && ! -e "$M_TEST_LOG.headers" ]] \
  || fail "static catalog provider made a network request"

# Without a model in a non-interactive shell, m installs the provider's static
# env block (its ~anthropic/... defaults) and clears dynamic selection keys.
run openrouter
assert_jq '.env.ANTHROPIC_MODEL == "~anthropic/claude-sonnet-latest"
           and (.env | has("M_SWITCHER_MODEL") | not)
           and (.modelOverrides | has("claude-sonnet-4-6") | not)' "$SETTINGS" \
  "default OpenRouter switch did not install the static env block"

# Returning to Claude removes every provider-owned and dynamic selection key
# while preserving user-owned settings.
run claude
assert_jq '.env == {"KEEP_ME":"yes"} and .permissions.allow == ["Read"]
           and .modelOverrides == {"claude-opus-4-6":"user/opus-route"}' "$SETTINGS" \
  "Claude round trip left provider keys or removed user settings"
run status
grep -q '^active: claude (anthropic default)' "$OUTPUT" || fail "status did not report the Anthropic default"

# A user-owned entry at m-switcher's recognition key is never overwritten or
# later removed. The switch still works, but explains that Claude's cosmetic
# unknown-model diagnostic may remain.
jq '.modelOverrides["claude-sonnet-4-6"] = "user/sonnet-route"' \
  "$SETTINGS" > "$SETTINGS.next"
mv "$SETTINGS.next" "$SETTINGS"
run openrouter openrouter/free
assert_jq '.modelOverrides["claude-sonnet-4-6"] == "user/sonnet-route"
           and (.env | has("M_SWITCHER_MODEL_OVERRIDE_KEY") | not)' "$SETTINGS" \
  "user-owned recognition override was overwritten"
grep -q 'kept your existing modelOverrides.claude-sonnet-4-6' "$OUTPUT" \
  || fail "override collision was not explained"
run claude
assert_jq '.modelOverrides["claude-sonnet-4-6"] == "user/sonnet-route"' "$SETTINGS" \
  "user-owned recognition override was removed"

# --- plain providers and the ~/.claude.json merge ---------------------------
printf '%s\n' '{"oauthAccount":{"e":"x"},"hasCompletedOnboarding":false,"numStartups":3}' > "$CLAUDE_JSON"
chmod 644 "$CLAUDE_JSON"
claude_json_before="$(snapshot "$CLAUDE_JSON")"

run zai
assert_jq '.env.ANTHROPIC_BASE_URL == "https://api.z.ai/api/anthropic"
           and .env.ANTHROPIC_AUTH_TOKEN == "zai-key"
           and .env.KEEP_ME == "yes"
           and .env.CLAUDE_CODE_SUBAGENT_MODEL == .env.ANTHROPIC_MODEL
           and .env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE == "1"
           and (.env | has("ANTHROPIC_API_KEY") | not)
           and (.env | has("M_SWITCHER_MODEL") | not)' "$SETTINGS" \
  "plain provider switch did not install the Z.ai env block"
[[ "$(snapshot "$CLAUDE_JSON")" == "$claude_json_before" ]] || fail "switching to Z.ai touched claude.json"
run status
grep -q '^active: Z.ai (GLM)' "$OUTPUT" || fail "status did not derive Z.ai from its base URL"

# Cross-provider switch: no Z.ai key survives, Kimi's flags are merged into
# ~/.claude.json additively with a private backup of the previous file.
run kimi
assert_jq '.env.ANTHROPIC_BASE_URL == "https://api.kimi.com/coding/"
           and .env.ANTHROPIC_API_KEY == "kimi-key"
           and (.env | has("ANTHROPIC_AUTH_TOKEN") | not)
           and (.env | has("API_TIMEOUT_MS") | not)
           and (.env | has("CLAUDE_CODE_SUBAGENT_MODEL_FORCE") | not)
           and .env.KEEP_ME == "yes"
           and .permissions.allow == ["Read"]' "$SETTINGS" \
  "cross-provider switch leaked Z.ai keys or lost user settings"
assert_jq '.oauthAccount.e == "x" and .numStartups == 3
           and .hasCompletedOnboarding == true and .penguinModeOrgEnabled == true' "$CLAUDE_JSON" \
  "claude.json was not merged additively"
assert_private "$CLAUDE_JSON" "claude.json is not private after the merge"
assert_private "$CLAUDE_JSON.bak" "claude.json.bak is not private"
assert_jq '.hasCompletedOnboarding == false' "$CLAUDE_JSON.bak" "claude.json.bak does not hold the previous file"
run status
grep -q '^active: Kimi Code' "$OUTPUT" || fail "status did not derive Kimi from its base URL"

# A repeated switch is a no-op for claude.json (no rewrite, backup untouched).
run kimi
assert_jq '.hasCompletedOnboarding == false' "$CLAUDE_JSON.bak" "claude.json was rewritten although nothing changed"

# A broken ~/.claude.json blocks the switch before settings.json is touched
# and leaves no temp file behind.
run zai
printf 'not json' > "$CLAUDE_JSON"
before="$(snapshot "$SETTINGS")"
expect_rc 1 kimi
grep -q 'not a JSON object' "$OUTPUT" || fail "broken claude.json was not explained: $(cat "$OUTPUT")"
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "settings were switched despite a broken claude.json"
[[ "$(cat "$CLAUDE_JSON")" == "not json" ]] || fail "broken claude.json was modified"
litter=("$CLAUDE_JSON".??????(N))
(( ${#litter} == 0 )) || fail "temp file left next to claude.json: ${litter[*]}"
printf '[]\n' > "$CLAUDE_JSON"
expect_rc 1 kimi
[[ "$(snapshot "$SETTINGS")" == "$before" ]] || fail "settings were switched despite an array claude.json"

# An empty ~/.claude.json is treated as {}.
: > "$CLAUDE_JSON"
run kimi
assert_jq '. == {"penguinModeOrgEnabled":true,"hasCompletedOnboarding":true}' "$CLAUDE_JSON" \
  "empty claude.json was not treated as an empty object"

# A missing ~/.claude.json is created.
rm -f "$CLAUDE_JSON"
run zai
run kimi
assert_jq '.penguinModeOrgEnabled == true' "$CLAUDE_JSON" "missing claude.json was not created"

run claude
assert_jq '.env == {"KEEP_ME":"yes"}' "$SETTINGS" "round trip from Kimi left provider keys"

# --- environment robustness -------------------------------------------------
# User shell options in ~/.zshenv (noclobber, ksharrays) must not change what
# m writes or which endpoint it pins.
mkdir -p "$TEST_TMP/zdot"
printf 'setopt noclobber ksharrays\n' > "$TEST_TMP/zdot/.zshenv"
ZDOTDIR="$TEST_TMP/zdot" run openrouter z-ai/glm-5.2
assert_jq '.env.M_SWITCHER_ENDPOINT == "streamlake/fp8"' "$SETTINGS" \
  "user shell options changed the pinned endpoint"
run claude

# Symlinked config files are written through, not replaced.
ln -s "$SETTINGS" "$TEST_TMP/settings.link.json"
M_SETTINGS="$TEST_TMP/settings.link.json" run zai
[[ -L "$TEST_TMP/settings.link.json" ]] || fail "symlinked settings.json was replaced by a regular file"
assert_jq '.env.ANTHROPIC_BASE_URL == "https://api.z.ai/api/anthropic"' "$SETTINGS" \
  "write through the settings symlink did not reach the target"
run claude

# A fresh install can run m before Claude Code has created settings.json.
mkdir -p "$TEST_TMP/fresh"
M_SETTINGS="$TEST_TMP/fresh/settings.json" run status
grep -q '^active: claude' "$OUTPUT" || fail "m did not run without a settings.json"
grep -q 'created' "$OUTPUT.err" || fail "creating settings.json was not announced"
[[ "$(cat "$TEST_TMP/fresh/settings.json")" == "{}" ]] || fail "created settings.json is not an empty object"
assert_private "$TEST_TMP/fresh/settings.json" "created settings.json is not private"
rc=0
M_SETTINGS="$TEST_TMP/nodir/settings.json" m status > "$OUTPUT" 2>&1 || rc=$?
(( rc == 1 )) || fail "missing settings directory exited $rc, expected 1"

# --- install.sh -------------------------------------------------------------
home="$TEST_TMP/home"
mkdir -p "$home"
HOME="$home" sh "$ROOT/install.sh" > "$OUTPUT"
[[ -x "$home/.local/bin/m" ]] || fail "install.sh did not install m"
grep -q 'created ~/.claude/providers.json' "$OUTPUT" || fail "install.sh did not report creating providers.json"
assert_private "$home/.claude/providers.json" "installed providers.json is not private"
HOME="$home" sh "$ROOT/install.sh" > "$OUTPUT"
grep -q 'kept existing' "$OUTPUT" || fail "second install.sh run was not a no-op"

# Upgrade path: a hand-made 644 providers.json with a real key and a stale
# 644 backup are merged with the bundled defaults and made private.
home2="$TEST_TMP/home2"
mkdir -p "$home2/.claude"
printf '%s\n' '{"zai":{"label":"Z","env":{"ANTHROPIC_AUTH_TOKEN":"real"}}}' > "$home2/.claude/providers.json"
printf '{}\n' > "$home2/.claude/settings.json.bak"
chmod 644 "$home2/.claude/providers.json" "$home2/.claude/settings.json.bak"
HOME="$home2" sh "$ROOT/install.sh" > "$OUTPUT"
grep -q 'added new bundled provider fields' "$OUTPUT" || fail "install.sh did not merge new providers"
assert_jq '.zai.env.ANTHROPIC_AUTH_TOKEN == "real" and .zai.label == "Z" and has("openrouter")' \
  "$home2/.claude/providers.json" "install.sh merge lost user values or new providers"
assert_private "$home2/.claude/providers.json" "merged providers.json is not private"
assert_private "$home2/.claude/providers.json.bak" "providers.json.bak from install.sh is not private"
assert_private "$home2/.claude/settings.json.bak" "install.sh did not repair a stale settings.json.bak"

# A symlinked providers.json is updated in place.
home3="$TEST_TMP/home3"
mkdir -p "$home3/.claude" "$home3/dotfiles"
printf '%s\n' '{"zai":{"label":"Z","env":{"ANTHROPIC_AUTH_TOKEN":"real"}}}' > "$home3/dotfiles/providers.json"
ln -s "$home3/dotfiles/providers.json" "$home3/.claude/providers.json"
HOME="$home3" sh "$ROOT/install.sh" > "$OUTPUT"
[[ -L "$home3/.claude/providers.json" ]] || fail "install.sh replaced a symlinked providers.json"
assert_jq 'has("openrouter") and .zai.env.ANTHROPIC_AUTH_TOKEN == "real"' "$home3/dotfiles/providers.json" \
  "install.sh did not update the symlink target"
assert_private "$home3/dotfiles/providers.json" "symlink target was not made private"

# --- secrets never reach argv; auth always reaches the API ------------------
grep -q '^Authorization: Bearer sk-or-test$' "$M_TEST_LOG.headers" \
  || fail "OpenRouter requests were not authenticated through the header file"
for secret in sk-or-test sk-bad zai-key kimi-key; do
  if grep -q -- "$secret" "$ARGV_LOG"; then fail "secret '$secret' appeared in a jq/curl argv"; fi
done

echo "ok - m-switcher integration tests"
