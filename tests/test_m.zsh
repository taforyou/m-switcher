#!/bin/zsh
set -e

ROOT="${0:A:h:h}"
TEST_TMP="$(mktemp -d)"
SETTINGS="$TEST_TMP/settings.json"
PROVIDERS="$TEST_TMP/providers.json"
CLAUDE_JSON="$TEST_TMP/claude.json"
OUTPUT="$TEST_TMP/output"
M_TEST_LOG="$TEST_TMP/request.json"

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

printf '%s\n' '{"env":{"KEEP_ME":"yes"},"permissions":{"allow":["Read"]},"modelOverrides":{"claude-opus-4-6":"user/opus-route"}}' > "$SETTINGS"
cp "$ROOT/providers.example.json" "$PROVIDERS"

# The key command reads from stdin without echoing it, validates it, and saves
# only after validation succeeds.
printf '%s\n' 'sk-or-test' | "$ROOT/m" key openrouter > "$OUTPUT"
assert_jq '.openrouter.env.ANTHROPIC_AUTH_TOKEN == "sk-or-test"' "$PROVIDERS" \
  "OpenRouter key was not saved"

# Prefix search should put Q-prefixed models in the result and exclude models
# that do not match the prefix/substring.
"$ROOT/m" models openrouter Q > "$OUTPUT"
grep -q '^qwen/qwen3-coder' "$OUTPUT" || fail "Q search did not find Qwen"
if grep -q 'z-ai/glm-5.2' "$OUTPUT"; then fail "Q search included an unrelated model"; fi
"$ROOT/m" models openrouter free > "$OUTPUT"
grep -q '^openrouter/free' "$OUTPUT" || fail "automatic free router was not listed"

# Endpoints are tool-capable only, cheapest first, with the live discount
# rounded in the same style as OpenRouter's UI.
"$ROOT/m" endpoints openrouter z-ai/glm-5.2 > "$OUTPUT"
first_endpoint="$(sed -n '1p' "$OUTPUT")"
[[ "$first_endpoint" == streamlake/fp8* ]] || fail "cheapest endpoint was not first"
[[ "$first_endpoint" == *'(77% off)'* ]] || fail "discount was not displayed"
if grep -q '^notools' "$OUTPUT"; then fail "endpoint without tools was listed"; fi

# A non-interactive model switch chooses the current cheapest endpoint, creates
# an exact-routing preset, and assigns it to every Claude Code model role.
"$ROOT/m" openrouter z-ai/glm-5.2 > "$OUTPUT"
assert_jq '.env.ANTHROPIC_BASE_URL == "https://openrouter.ai/api"' "$SETTINGS" \
  "OpenRouter base URL was not installed"
assert_jq '.env.ANTHROPIC_API_KEY == ""' "$SETTINGS" \
  "Anthropic API key was not explicitly blanked"
assert_jq '.env.ANTHROPIC_MODEL
           | startswith("@preset/m-switcher-") and endswith("[1m]")' "$SETTINGS" \
  "routing preset was not selected"
assert_jq '.env.ANTHROPIC_MODEL == .env.ANTHROPIC_DEFAULT_OPUS_MODEL
           and .env.ANTHROPIC_MODEL == .env.ANTHROPIC_DEFAULT_SONNET_MODEL
           and .env.ANTHROPIC_MODEL == .env.ANTHROPIC_DEFAULT_HAIKU_MODEL
           and .env.ANTHROPIC_MODEL == .env.CLAUDE_CODE_SUBAGENT_MODEL' "$SETTINGS" \
  "not every Claude Code model role uses the selected route"
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
assert_jq '.provider.only == ["streamlake/fp8"]
           and .provider.allow_fallbacks == false' "$M_TEST_LOG" \
  "preset does not pin the exact endpoint"

"$ROOT/m" status > "$OUTPUT"
grep -q 'model: z-ai/glm-5.2' "$OUTPUT" || fail "status omitted selected model"
grep -q 'endpoint: StreamLake' "$OUTPUT" || fail "status omitted selected endpoint"
grep -q 'context: 1024000 tokens' "$OUTPUT" || fail "status omitted endpoint context"

# An explicit endpoint tag overrides the cheapest default.
"$ROOT/m" openrouter z-ai/glm-5.2 regularcloud/fp8 > "$OUTPUT"
assert_jq '.env.M_SWITCHER_ENDPOINT == "regularcloud/fp8"
           and .env.M_SWITCHER_ENDPOINT_NAME == "RegularCloud"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "524288"
           and (.env.ANTHROPIC_MODEL | endswith("[1m]") | not)
           and (.modelOverrides | has("claude-sonnet-4-6") | not)' "$SETTINGS" \
  "explicit endpoint selection did not override the cheapest endpoint"

# The automatic free router is a direct model route: it lets OpenRouter choose
# a tool-capable free model per request and therefore skips endpoint pinning.
"$ROOT/m" openrouter openrouter/free > "$OUTPUT"
assert_jq '.env.ANTHROPIC_MODEL == "openrouter/free"
           and .env.ANTHROPIC_DEFAULT_OPUS_MODEL == "openrouter/free"
           and .env.M_SWITCHER_MODEL == "openrouter/free"
           and .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "200000"
           and .modelOverrides["claude-sonnet-4-6"] == "openrouter/free"
           and (.env | has("M_SWITCHER_ENDPOINT") | not)' "$SETTINGS" \
  "automatic free router was not configured as a direct route"
"$ROOT/m" status > "$OUTPUT"
grep -q 'model: openrouter/free' "$OUTPUT" || fail "status omitted free router"
if grep -q 'endpoint:' "$OUTPUT"; then fail "free router incorrectly reported a pinned endpoint"; fi

# Returning to Claude removes every provider-owned and dynamic selection key
# while preserving user-owned settings.
"$ROOT/m" claude > "$OUTPUT"
assert_jq '.env == {"KEEP_ME":"yes"} and .permissions.allow == ["Read"]
           and .modelOverrides == {"claude-opus-4-6":"user/opus-route"}' "$SETTINGS" \
  "Claude round trip left provider keys or removed user settings"

# A user-owned entry at m-switcher's recognition key is never overwritten or
# later removed. The switch still works, but explains that Claude's cosmetic
# unknown-model diagnostic may remain.
jq '.modelOverrides["claude-sonnet-4-6"] = "user/sonnet-route"' \
  "$SETTINGS" > "$SETTINGS.next"
mv "$SETTINGS.next" "$SETTINGS"
"$ROOT/m" openrouter openrouter/free > "$OUTPUT"
assert_jq '.modelOverrides["claude-sonnet-4-6"] == "user/sonnet-route"
           and (.env | has("M_SWITCHER_MODEL_OVERRIDE_KEY") | not)' "$SETTINGS" \
  "user-owned recognition override was overwritten"
grep -q 'kept your existing modelOverrides.claude-sonnet-4-6' "$OUTPUT" \
  || fail "override collision was not explained"
"$ROOT/m" claude > "$OUTPUT"
assert_jq '.modelOverrides["claude-sonnet-4-6"] == "user/sonnet-route"' "$SETTINGS" \
  "user-owned recognition override was removed"

echo "ok - m-switcher integration tests"
