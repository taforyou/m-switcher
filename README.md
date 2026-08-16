# m — provider, model, and endpoint switcher for Claude Code

`m` switches Claude Code between Anthropic and compatible API providers without
overwriting the rest of `~/.claude/settings.json`.

OpenRouter support includes the full routing flow:

```text
m → OpenRouter → search/select a model → select its hosting endpoint → start claude
```

Models and endpoint prices are loaded live. Hosting endpoints are limited to
healthy endpoints with tool support, sorted cheapest first, and annotated with
OpenRouter's current discount:

```text
Hosting endpoints — cheapest is selected by default
  * StreamLake [streamlake/fp8] $0.3248/$1.0208/M fp8 (77% off)
    Novita [novita/fp8]         $0.3388/$1.0648/M fp8 (76% off)
```

`*` marks the cheapest endpoint. Prices and discounts change, so the actual
list is refreshed whenever you select a model.

## Install

Requirements: `zsh`, `jq`, and `curl`.

```bash
git clone https://github.com/taforyou/m-switcher.git
cd m-switcher
./install.sh
```

The installer puts `m` in `~/.local/bin`, creates
`~/.claude/providers.json` when needed, and adds newly bundled providers to an
existing file without overwriting entries you have customized.

## OpenRouter quick start

Create an API key in the [OpenRouter dashboard](https://openrouter.ai/keys),
then save and validate it without exposing it on the command line:

```bash
m key openrouter
m
```

Choose `OpenRouter`, then:

1. Type to search models. Typing `Q` immediately lists Qwen and other matching
   `Q` model IDs/names. Backspace edits the query; arrows move; return selects.
2. Select a hosting endpoint. The cheapest compatible endpoint is highlighted
   by default, and discounts such as `(77% off)` appear at the end of the row.
3. Restart `claude`, then use `/status` to verify the base URL is
   `https://openrouter.ai/api`.

If Claude Code was previously logged into a Claude subscription, run `/logout`
once before starting the OpenRouter session. OpenRouter specifically requires
`ANTHROPIC_AUTH_TOKEN`, the base URL without `/v1`, and an explicitly empty
`ANTHROPIC_API_KEY`; the bundled configuration sets all three. See
[OpenRouter's Claude Code guide](https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration).

## Command-line use

```bash
m                              # interactive provider picker
m openrouter                   # OpenRouter model + endpoint pickers
m openrouter Q                 # open model picker pre-filtered by Q
m openrouter openrouter/free   # automatically choose a tool-capable free model
m openrouter z-ai/glm-5.2 streamlake/fp8
                               # pin GLM 5.2 to StreamLake exactly

m models openrouter Q          # list matching tool-capable models
m endpoints openrouter z-ai/glm-5.2
                               # list healthy endpoints, price, and discount

m zai                          # switch directly to another configured provider
m kimi
m claude                       # return to Anthropic and remove provider env
m status                       # active provider, model, and endpoint
```

In a non-interactive shell, `m openrouter <exact-model>` automatically selects
the current cheapest healthy, tool-capable endpoint. Supplying the endpoint tag
as the third argument pins it explicitly.

`openrouter/free` is shown as **Free Models Router (automatic)** at the top of
the model catalog. It skips endpoint selection because OpenRouter chooses a
currently available free model for each request and filters that pool for
required capabilities such as tool calling. Free routes have lower rate limits,
variable availability/performance, and may use providers that log prompts; see
[OpenRouter's free-router documentation](https://openrouter.ai/docs/guides/routing/routers/free-router).

## How exact endpoint selection works

OpenRouter model IDs choose a model, while an exact host such as StreamLake is
selected with the request body's `provider.only` field. Claude Code does not
have an environment variable for that field.

To bridge the two, `m` creates a deterministic OpenRouter
[preset](https://openrouter.ai/docs/guides/features/presets) for the selected
model and endpoint:

```json
{
  "model": "z-ai/glm-5.2",
  "provider": {
    "only": ["streamlake/fp8"],
    "allow_fallbacks": false
  }
}
```

Claude Code is then configured to use `@preset/m-switcher-…` for its main,
Opus, Sonnet, Haiku, Fable, and subagent roles. Existing identical presets are
reused. Exact pinning deliberately disables provider fallback: if the selected
endpoint is unavailable, the request fails instead of silently using a more
expensive host. Run `m` again to choose another endpoint.

The selected endpoint's live `context_length` is also written to
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`. Generated `@preset/...` IDs are unknown to
Claude Code, which otherwise assumes a 200K context window. Declaring the real
endpoint limit keeps proactive auto-compaction enabled. For windows Claude Code
can identify exactly, `m` also installs a scoped `modelOverrides` mapping to
remove the unrecognized-model notice: 200K routes map directly, and endpoints
advertising at least 1M receive the provider-stripped `[1m]` suffix. Other
window sizes keep their exact limit even though Claude may continue to show an
informational unknown-model notice.

For `openrouter/free`, the concrete model changes per request, so `m` uses a
conservative 200K window and a 200K recognition mapping instead of falsely
marking the router as a 1M model. If your settings already use the same
`modelOverrides` key, `m` preserves it and prints a note rather than replacing
it.

OpenRouter documents the exact endpoint tags and `provider.only` behavior in
its [provider-routing guide](https://openrouter.ai/docs/guides/routing/provider-selection),
and publishes live endpoint pricing/discount data through its
[model endpoints API](https://openrouter.ai/docs/api/api-reference/endpoints/list-all-endpoints-for-a-model).

## Compatibility note

The model picker shows text-output models that advertise tool calling because
Claude Code depends heavily on tools. OpenRouter warns that Claude Code is only
guaranteed with Anthropic's first-party provider; other models/endpoints may
still differ in tool accuracy, thinking support, prompt caching, or beta
features. A large discount is useful information, not a compatibility
guarantee.

## Other providers

Providers live in `~/.claude/providers.json`:

```json
{
  "myprovider": {
    "label": "shown in the picker",
    "env": {
      "ANTHROPIC_AUTH_TOKEN": "provider key",
      "ANTHROPIC_BASE_URL": "https://provider.example/anthropic",
      "ANTHROPIC_DEFAULT_SONNET_MODEL": "model-id"
    },
    "claudeJson": { "optional": "flags merged into ~/.claude.json" }
  }
}
```

The bundled non-OpenRouter examples are:

- **Z.ai (GLM)** — `https://api.z.ai/api/anthropic`, authenticated with
  `ANTHROPIC_AUTH_TOKEN`.
- **Kimi Code** — the subscription service at
  `https://api.kimi.com/coding/`, authenticated with a key from the
  [Kimi Code Console](https://www.kimi.com/code/console). It is distinct from
  the pay-per-token Moonshot platform.

## Safety properties

- **Scoped writes.** Switching removes only environment keys claimed by a
  configured provider or its dynamic model selection. Hooks, permissions, and
  unrelated environment variables are preserved.
- **Atomic with backups.** Settings and provider-key changes use a temporary
  file and keep the previous file as `.bak`.
- **Key validation.** `m key openrouter` hides input and validates it through
  OpenRouter's `/api/v1/key` endpoint before saving. Keys remain stored locally
  in `~/.claude/providers.json`, which the installer and key command protect
  with mode `600`.
- **No silent endpoint fallback.** Exact endpoint presets use `only` and set
  `allow_fallbacks` to false.
- **Accurate context limits.** The endpoint's advertised context length
  configures Claude Code's unknown-model window automatically. The less-safe
  `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT` escape hatch is not
  enabled.
- **Scoped recognition mapping.** m-switcher's own `modelOverrides` entry is
  removed when the route changes or you return to Claude. Existing user-owned
  overrides are preserved.
- **Test paths.** `M_SETTINGS`, `M_CLAUDE_JSON`, and `M_PROVIDERS` can point to
  isolated files.

## Test

```bash
tests/test_m.zsh
```

The suite uses a mock OpenRouter API and verifies key storage, prefix search,
discount ordering, exact endpoint pinning, settings preservation, status, and
the round trip back to Anthropic.

## Troubleshooting

- **OpenRouter auth/model-not-found errors:** run `/logout`, quit Claude Code,
  and start it again. Confirm `/status` names `ANTHROPIC_AUTH_TOKEN` and shows
  `https://openrouter.ai/api` (not `/api/v1`).
- **No model in search:** only tool-capable text models are shown. Check the
  exact current ID with `m models openrouter <query>`.
- **Selected host fails:** exact endpoint routing has no fallback by design.
  Run `m openrouter <model>` and select another host.
- **`... is not a model this version recognizes`:** install the current
  version, then select the model/endpoint again. The StreamLake GLM 5.2 route
  and `openrouter/free` both get safe recognition mappings automatically. An
  endpoint with a nonstandard window such as 128K, 262K, or 512K may retain the
  notice, but its exact compaction limit is configured. Do not append `[1m]` to
  `openrouter/free`; its routed model varies by request.
- **Rolled a bad config:** the previous settings file is
  `~/.claude/settings.json.bak`.

## License

MIT
