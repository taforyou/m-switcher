# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` holds the contributor conventions (style, commit/PR expectations); `methodology.md` documents the design rationale behind every invariant below. Read `methodology.md` before changing settings-write or routing logic.

## Commands

```bash
zsh -n m                                     # syntax-check the main script
sh -n install.sh tests/bin/curl tests/bin/jq # syntax-check the POSIX scripts
jq empty providers.example.json tests/fixtures/*.json
tests/test_m.zsh                             # full suite (isolated tmpdir + mocked curl)
git diff --check
```

`tests/test_m.zsh` is a single linear zsh script with no test selection flag — to run one case, comment out the others or copy the block into a scratch script that reuses the same `M_*` exports. `./install.sh` mutates real user config; it is not a test command.

## Architecture

Everything is one zsh script, `m` (~1,000 lines). There is no build step. State lives entirely in three JSON files, whose paths are overridable for testing:

| Var | Default | Role |
| --- | --- | --- |
| `M_PROVIDERS` | `~/.claude/providers.json` | provider definitions **and** API keys (mode 600) |
| `M_SETTINGS` | `~/.claude/settings.json` | Claude Code settings that `m` rewrites |
| `M_CLAUDE_JSON` | `~/.claude.json` | optional per-provider flags merged in |

`providers.example.json` is the shipped template; `install.sh` merges *new* provider keys into an existing `providers.json` without overwriting customized entries.

### Provider entries drive behavior, not code

A provider is `{label, env, claudeJson?, modelCatalog?}`. Adding a simple provider is a pure data change. `modelCatalog` is what unlocks the OpenRouter flow: it names the models/endpoints/presets URLs plus the env keys `m` is allowed to write (`modelEnv`, `selectionEnv`, `contextEnv`, `recognitionOverride`, `specialModels`, `excludeIdSuffixes` — catalog variants hidden from the picker and rejected by `model_exists`, bundled `[":batch"]`). Code reads these key *names* from JSON rather than hardcoding them, so a second catalog provider is expressible in `providers.json` alone *if* it speaks OpenRouter's API shapes (`.data[]` models, `.data.endpoints[]`, presets at `<presetsUrl>/<slug>[/messages]`).

### Invariants that tests enforce

- **Strip-then-merge, never toggle.** `switch_to()` computes the union of env keys owned by *all* providers (`env` + `modelEnv` + `selectionEnv` + `contextEnv`), deletes them, then merges the target's block. Switching is stateless and idempotent; unrelated env keys and top-level settings survive. Any new env key `m` writes must be added to a provider's owned-key lists or it will leak across switches.
- **Active provider is derived, not stored.** `current()` matches `settings.env.ANTHROPIC_BASE_URL` against provider entries. No state file exists — don't add one.
- **Atomic writes with backup, everything mode 600.** Write to `mktemp`, `cp` the original to `.bak`, `chmod 600` the backup (cp keeps a pre-existing .bak's mode), then `mv`. If jq fails the original is untouched. `umask 077` is set at the top of `m` and `install.sh`; `SETTINGS`/`PROV`/`CLAUDE_JSON` are resolved through symlinks (`:A`) at startup so dotfiles setups are written through. The `claudeJson` merge into `~/.claude.json` is prepared and validated *before* settings.json is committed and is committed first, so a broken `~/.claude.json` blocks the switch rather than half-applying it; it is skipped when it would be a no-op.
- **jq only.** Never parse or edit JSON with sed/regex.
- **Keys never hit argv.** `http_request()` passes the auth header via a temp header file (mode 600, `curl -q` so `~/.curlrc` cannot echo it) and returns results through the globals `HTTP_STATUS` / `HTTP_DATA`; `configure_key()` hands the token to jq through the environment (`env.value`). The test harness traces every jq/curl argv spawned by `m` and fails if a key appears.
- **`m key <provider>`** reads the key with echo off, validates it against `modelCatalog.validationUrl` when one exists, and only then saves; providers without a URL (Z.ai, Kimi) are saved with a "(not validated)" message.
- **Signals and terminal state.** `always` blocks do not run on SIGINT/errexit in zsh, so `cleanup()` (INT/TERM/HUP/EXIT traps) restores the cursor and tty and removes files registered in `M_TMP_FILES`. Register any new temp file there. Pickers go through `picker_enter`/`picker_line`/`read_key`/`picker_leave`: lines are clipped to the terminal width (a wrapped line breaks the fixed `\e[13A` redraw), the tty stays raw for the whole picker, and unknown escape sequences are ignored rather than treated as cancel.

### OpenRouter routing flow

`catalog_switch()` is the spine: `ensure_credential` → `fetch_models` → `model_picker` → `fetch_endpoints` → `endpoint_picker` → `ensure_routing_preset` → `switch_to`. Both pickers fall back to non-interactive behavior when stdin/stdout are not a TTY (exact model required; cheapest healthy tool-capable endpoint auto-selected).

Exact host selection cannot be expressed in an env var, so `ensure_routing_preset()` creates a deterministic OpenRouter preset (`m-switcher-<slug>-<cksum>`) carrying `provider.only: [tag]`, `allow_fallbacks: false` and — for a bare provider tag such as `fireworks`, which OpenRouter's base-slug matching would extend to `fireworks/fast` — `provider.ignore: [sibling tags]`, then writes `@preset/…` into every model role env var. Identical presets are reused (GET first; POST when the preset is missing (404) or its designated config differs). Fallback stays disabled deliberately — a dead endpoint should fail loudly rather than silently reroute to a pricier host.

`specialModels` entries with `direct: true` (currently `openrouter/free`) bypass endpoint selection and presets entirely; `model_routes_directly()` gates that path.

### Context length and `modelOverrides`

`@preset/…` IDs are unknown to Claude Code, which would assume 200K. `m` writes the endpoint's live `context_length` to `CLAUDE_CODE_MAX_CONTEXT_TOKENS` so auto-compaction stays accurate. Separately it installs a scoped `modelOverrides` entry (key from `recognitionOverride`) *only* when the window is exactly 200K or ≥1M (the latter gets Claude Code's `[1m]` suffix) — mapping any other size would lie about the window. `m` tracks its own override via `M_SWITCHER_MODEL_OVERRIDE_KEY`/`_VALUE` so it removes only what it wrote; a pre-existing user override is preserved and reported as a note.

### Tests

`tests/test_m.zsh` runs against a temp settings/providers/claude.json (seeded 644 with stale 644 backups, like real machines) and puts `tests/bin` on `PATH`. There a POSIX `curl` mock dispatches on URL to `tests/fixtures/*.json`, requires the test key (`sk-or-test`) in the header file for `/api/v1/key` and preset calls (401 otherwise), persists created presets so `GET` can serve them (exercising the reuse branch), returns 500 for `/models` when `M_TEST_FAIL_MODELS=1`, and logs the last preset POST body to `$M_TEST_LOG`, headers to `$M_TEST_LOG.headers`, and `METHOD URL` lines to `$M_TEST_LOG.requests`. A `jq` wrapper and the mock both append their argv to `$M_TEST_ARGV_LOG`, which the suite sets only for `m` runs (via the `m`/`run`/`expect_rc` helpers) and greps for keys at the end. `install.sh` is exercised under a scratch `$HOME`. Extend the fixtures and the mock's `case` arms rather than making live calls. Every routing or settings change needs a case asserting both the new behavior and the preservation of unrelated settings (`KEEP_ME`, `permissions`, the user-owned `modelOverrides` entry seeded at the top of the suite); use `expect_rc` for refusal paths so exit codes are asserted. The interactive pickers are not covered — drive them under a pty (`expect`) when touching them.
