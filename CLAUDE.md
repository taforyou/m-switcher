# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` holds the contributor conventions (style, commit/PR expectations); `methodology.md` documents the design rationale behind every invariant below. Read `methodology.md` before changing settings-write or routing logic.

## Commands

```bash
zsh -n m                                     # syntax-check the main script
sh -n install.sh tests/bin/curl              # syntax-check the POSIX scripts
jq empty providers.example.json tests/fixtures/*.json
tests/test_m.zsh                             # full suite (isolated tmpdir + mocked curl)
git diff --check
```

`tests/test_m.zsh` is a single linear zsh script with no test selection flag — to run one case, comment out the others or copy the block into a scratch script that reuses the same `M_*` exports. `./install.sh` mutates real user config; it is not a test command.

## Architecture

Everything is one zsh script, `m` (~830 lines). There is no build step. State lives entirely in three JSON files, whose paths are overridable for testing:

| Var | Default | Role |
| --- | --- | --- |
| `M_PROVIDERS` | `~/.claude/providers.json` | provider definitions **and** API keys (mode 600) |
| `M_SETTINGS` | `~/.claude/settings.json` | Claude Code settings that `m` rewrites |
| `M_CLAUDE_JSON` | `~/.claude.json` | optional per-provider flags merged in |

`providers.example.json` is the shipped template; `install.sh` merges *new* provider keys into an existing `providers.json` without overwriting customized entries.

### Provider entries drive behavior, not code

A provider is `{label, env, claudeJson?, modelCatalog?}`. Adding a simple provider is a pure data change. `modelCatalog` is what unlocks the OpenRouter flow: it names the models/endpoints/presets URLs plus the env keys `m` is allowed to write (`modelEnv`, `selectionEnv`, `contextEnv`, `recognitionOverride`, `specialModels`). Code reads these key *names* from JSON rather than hardcoding them, so a second catalog provider should be expressible in `providers.json` alone.

### Invariants that tests enforce

- **Strip-then-merge, never toggle.** `switch_to()` computes the union of env keys owned by *all* providers (`env` + `modelEnv` + `selectionEnv` + `contextEnv`), deletes them, then merges the target's block. Switching is stateless and idempotent; unrelated env keys and top-level settings survive. Any new env key `m` writes must be added to a provider's owned-key lists or it will leak across switches.
- **Active provider is derived, not stored.** `current()` matches `settings.env.ANTHROPIC_BASE_URL` against provider entries. No state file exists — don't add one.
- **Atomic writes with backup.** Write to `mktemp`, `cp` the original to `.bak`, then `mv`. If jq fails the original is untouched.
- **jq only.** Never parse or edit JSON with sed/regex.
- **Keys never hit argv.** `http_request()` passes the auth header via a temp header file (mode 600) and returns results through the globals `HTTP_STATUS` / `HTTP_DATA`. Don't print authorization headers or move a token into curl arguments.
- **`m key <provider>`** reads the key with echo off, validates it against `modelCatalog.validationUrl`, and only then saves.

### OpenRouter routing flow

`catalog_switch()` is the spine: `ensure_credential` → `fetch_models` → `model_picker` → `fetch_endpoints` → `endpoint_picker` → `ensure_routing_preset` → `switch_to`. Both pickers fall back to non-interactive behavior when stdin/stdout are not a TTY (exact model required; cheapest healthy tool-capable endpoint auto-selected).

Exact host selection cannot be expressed in an env var, so `ensure_routing_preset()` creates a deterministic OpenRouter preset (`m-switcher-<slug>-<cksum>`) carrying `provider.only: [tag]` and `allow_fallbacks: false`, then writes `@preset/…` into every model role env var. Identical presets are reused (GET first, POST only on 404). Fallback stays disabled deliberately — a dead endpoint should fail loudly rather than silently reroute to a pricier host.

`specialModels` entries with `direct: true` (currently `openrouter/free`) bypass endpoint selection and presets entirely; `model_routes_directly()` gates that path.

### Context length and `modelOverrides`

`@preset/…` IDs are unknown to Claude Code, which would assume 200K. `m` writes the endpoint's live `context_length` to `CLAUDE_CODE_MAX_CONTEXT_TOKENS` so auto-compaction stays accurate. Separately it installs a scoped `modelOverrides` entry (key from `recognitionOverride`) *only* when the window is exactly 200K or ≥1M (the latter gets Claude Code's `[1m]` suffix) — mapping any other size would lie about the window. `m` tracks its own override via `M_SWITCHER_MODEL_OVERRIDE_KEY`/`_VALUE` so it removes only what it wrote; a pre-existing user override is preserved and reported as a note.

### Tests

`tests/test_m.zsh` runs against a temp settings/providers/claude.json and puts `tests/bin` on `PATH`, where a POSIX `curl` mock dispatches on URL to `tests/fixtures/*.json` and logs preset POST bodies to `$M_TEST_LOG`. Extend the fixtures and the mock's `case` arms rather than making live calls. Every routing or settings change needs a case asserting both the new behavior and the preservation of unrelated settings (`KEEP_ME`, `permissions`, the user-owned `modelOverrides` entry seeded at the top of the suite).
