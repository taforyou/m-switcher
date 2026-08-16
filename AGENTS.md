# Repository Guidelines

## Project Structure & Module Organization

This repository is a small shell-based Claude Code provider switcher. The main executable is `m`, a zsh script that updates Claude settings, queries live model catalogs, and manages OpenRouter endpoint presets. `install.sh` installs the command and merges defaults from `providers.example.json`. Design decisions and operational invariants are documented in `methodology.md`; user-facing setup belongs in `README.md`.

Tests live under `tests/`. `tests/test_m.zsh` is the integration suite, `tests/bin/curl` is a deterministic HTTP mock, and `tests/fixtures/*.json` contain mock OpenRouter responses. There is no compiled build or asset pipeline.

## Build, Test, and Development Commands

- `zsh -n m` — syntax-check the main zsh script.
- `sh -n install.sh tests/bin/curl tests/bin/jq` — syntax-check the POSIX installer and test shims.
- `jq empty providers.example.json tests/fixtures/*.json` — validate JSON files.
- `tests/test_m.zsh` — run isolated integration tests with temporary settings and mocked HTTP.
- `git diff --check` — detect whitespace errors before committing.
- `./install.sh` — install to `~/.local/bin/m`; this mutates real user configuration and is not a routine test command.

Run all non-mutating checks before submitting changes.

## Coding Style & Naming Conventions

Use two-space indentation in shell blocks and keep scripts compatible with their declared interpreter: zsh for `m`, POSIX `sh` for `install.sh` and the curl mock. Quote expansions, declare function-local values with `local`, and use `snake_case` for functions and local variables. Reserve uppercase names for shared state such as `HTTP_DATA` or `M_SETTINGS`.

Keep JSON manipulation in `jq`; do not parse or edit settings with regular expressions. Provider keys and command names should be lowercase, for example `openrouter`.

## Testing Guidelines

Add integration coverage for every routing or settings change. Tests should verify both the requested behavior and preservation of unrelated settings. Extend fixtures instead of making live network calls. Keep test failure messages actionable through the existing `fail` and `assert_jq` helpers.

## Security & Configuration Tips

Never commit real API keys or `~/.claude/providers.json`. Avoid printing authorization headers. Settings writes must remain atomic, backed up, and limited to provider-owned keys. Use `M_SETTINGS`, `M_PROVIDERS`, and `M_CLAUDE_JSON` for isolated manual tests.

## Commit & Pull Request Guidelines

Recent commits use imperative, descriptive subjects such as `Update Z.ai model version...`. Keep commits focused. Pull requests should explain the behavior change, list verification commands, note configuration or security implications, and include terminal output or screenshots when interactive picker behavior changes.
