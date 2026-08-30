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
  * [77%] StreamLake [streamlake/fp8] $0.3248/$1.0208/M fp8
    [76%] Novita [novita/fp8]         $0.3388/$1.0648/M fp8
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
   `Q` model IDs/names. Use left/right (or Tab) to switch between **All**,
   **Discounted**, and **Free** scopes. Backspace edits the query; up/down move;
   return selects.
   Each row includes the live input/output price per million tokens and is
   colored on a green-to-red scale: green is free, then yellow/orange, while
   red marks the most expensive models. **All** is ordered red-to-green,
   **Discounted** by largest percentage reduction, and **Free** by largest
   context window. Discounted rows put the promotion before the model name,
   for example `[90%] Qwen: Qwen3 Coder`, so large reductions are easy to scan.
   They show input/output prices per million tokens as the struck-through list
   price followed by `→` and the current promotional price. Promoted models
   use this same treatment in **All**.
2. Select a hosting endpoint. The cheapest compatible endpoint is highlighted
   by default, and discounts such as `[77%]` appear before the provider name.
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

m zai                          # Z.ai model picker (static GLM catalog)
m zai glm-5.3-flash            # switch Z.ai directly to a specific model
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

The **Free** scope also includes concrete `:free` variants and catalog entries
whose input, output, and request prices are all zero. Promotion metadata for
the **All** and **Discounted** scopes is loaded when the picker opens from
OpenRouter's live
[discounted-model collection](https://openrouter.ai/collections/discounted-models),
because the Models API publishes the discounted price but not the promotion
flag. If that collection cannot be reached or its format changes, the picker
keeps All and Free usable (without promotion decorations in All) and labels
only the Discounted scope unavailable.

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

A bare provider tag such as `fireworks` would also match that provider's
suffixed endpoints (`fireworks/fast`, regional variants) under OpenRouter's
base-slug matching, so `m` adds every sibling tag of the model to
`provider.ignore` in the preset; suffixed tags such as `streamlake/fp8` are
already exact. Catalog variants listed in `modelCatalog.excludeIdSuffixes`
(bundled: `:batch`, OpenRouter's Batch-API models) are hidden from the picker
and cannot be pinned.

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
  `ANTHROPIC_AUTH_TOKEN` (set it with `m key zai`; Z.ai has no
  key-validation endpoint, so the key is saved without validation). Z.ai
  publishes no models API, so the bundled entry ships its
  Claude-Code-capable chat lineup as a static catalog — `m zai` opens the
  model picker over GLM-5.3, GLM-5.3-Flash, GLM-5.2, GLM-5-Turbo, and
  GLM-4.7 (`m models zai` lists them; `m zai glm-5.3-flash` switches
  directly). Z.ai serves each model itself, so there is no endpoint picker
  or preset: the selected ID is written to every Claude Code model role.
  Context handling follows
  [Z.ai's devpack guide](https://docs.z.ai/devpack/latest-model): 1M-window
  models (GLM-5.3, GLM-5.3-Flash, GLM-5.2) are routed with the `[1m]`
  suffix and a 1,000,000-token `CLAUDE_CODE_MAX_CONTEXT_TOKENS` /
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; 200K models (GLM-5-Turbo, GLM-4.7)
  get their exact window without the suffix. GLM-OCR and GLM-ASR-2512 are
  document/speech models, not chat backends, and are deliberately not
  offered. Prices are Z.ai's published per-million rates and change only
  when the bundled file does, so the Discounted picker scope reports
  itself unconfigured for Z.ai.
- **Kimi Code** — the subscription service at
  `https://api.kimi.com/coding/`, authenticated with a key from the
  [Kimi Code Console](https://www.kimi.com/code/console). It is distinct from
  the pay-per-token Moonshot platform.
- **AI Passport** — Thai prepaid GPU provider serving a single model,
  `qwen3.8-27b`, at `https://aipassport.trirat.co` (the Anthropic Messages
  endpoint lives at the bare host — do not append `/v1`), authenticated with
  `ANTHROPIC_AUTH_TOKEN` (set it with `m key aipassport`; the key is saved
  without validation). All model roles point at `qwen3.8-27b` — it is the only
  model the gateway serves — and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is set to
  230,144 tokens to match the model's usable window (no `[1m]` suffix: that
  would claim a 1M window the endpoint does not serve).

## Safety properties

- **Scoped writes.** Switching removes only environment keys claimed by a
  configured provider or its dynamic model selection. Hooks, permissions, and
  unrelated environment variables are preserved.
- **Atomic with backups.** Settings, provider-key and `~/.claude.json` changes
  use a temporary file and keep the previous file as `.bak`. Every file `m`
  writes — including the backups, which hold the previous provider's key — is
  mode `600`; `./install.sh` also tightens backups left by earlier versions.
  Symlinked config files are written through, not replaced.
- **Key validation.** `m key openrouter` hides input and validates it through
  OpenRouter's `/api/v1/key` endpoint before saving; the key never appears on
  a command line (`curl` reads it from a private header file, `jq` from the
  environment). Providers without a `validationUrl` (Z.ai, Kimi) are saved and
  reported as *not validated*. Keys remain stored locally in
  `~/.claude/providers.json` with mode `600`.
- **Consistent switches.** A provider's `claudeJson` flags are validated and
  written to `~/.claude.json` before `settings.json` is committed, so a broken
  `~/.claude.json` blocks the switch instead of leaving it half-applied. Those
  flags are merged additively and stay in place after switching away.
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

The suite uses a mock OpenRouter API (`tests/bin/curl`, which also records
every request, header file and argv) and verifies key validation and storage,
prefix search, `:batch` exclusion, discount ordering, exact endpoint pinning
including sibling narrowing and preset reuse, static-catalog (Z.ai) listing,
search and offline routing with `[1m]` and exact 200K windows, plain-provider
switching and the `~/.claude.json` merge, file modes, symlinks, `install.sh`,
settings preservation, status, the round trip back to Anthropic, and that no
key ever reaches a `curl`/`jq` command line. A pseudo-TTY test also covers
picker scope navigation, scope-specific sorting and filtering, and green/red
price rendering.

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
  `~/.claude/settings.json.bak` (and `~/.claude.json.bak` when a provider's
  `claudeJson` flags were merged).
- **Picker looks wrong or the cursor disappeared:** the pickers clip every
  line to the terminal width and restore the cursor and tty on Ctrl-C; if a
  terminal still ends up in a bad state (for example after `kill -9`), run
  `reset`.

## License

MIT
