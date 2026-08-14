# m — provider switcher for Claude Code

Use Claude Code as your daily driver, but sometimes point it at another
Anthropic-compatible provider (Z.ai GLM, Kimi Code, …)? `m` switches the
`env` block in `~/.claude/settings.json` with one keystroke, the way `n`
switches Node versions:

```
$ m
  o claude (anthropic default)
    Z.ai (glm-5.3)
    Kimi Code (k3[1m])
  up/down to select, return to switch, q to quit
```

`o` marks the active provider. Arrow keys (or `j`/`k`) move, return
switches, `q` quits. Non-interactive forms:

```bash
m zai        # switch directly
m kimi
m claude     # back to Anthropic default (removes the env block)
m status     # print the active provider
```

Switching only affects **newly started** `claude` sessions — Claude Code
reads `env` at startup. The flow is: `m` → pick → start `claude`.
Verify with `/status` inside Claude Code: the Base URL should show your
provider's endpoint.

## Install

Requirements: `zsh` (macOS default) and `jq`.

```bash
git clone https://github.com/<you>/m-switcher && cd m-switcher
./install.sh
```

This puts `m` in `~/.local/bin` and creates `~/.claude/providers.json`
from `providers.example.json` if you don't have one. Then edit
`~/.claude/providers.json` and replace the `<placeholder>` keys with your
real ones. `m` refuses to switch to any provider whose key still starts
with `<`, so a half-configured file can never produce a broken session.

## Configuring providers

All providers live in one file, `~/.claude/providers.json`:

```json
{
  "myprovider": {
    "label": "shown in the picker",
    "env": {
      "ANTHROPIC_AUTH_TOKEN": "…or ANTHROPIC_API_KEY, whichever the provider documents",
      "ANTHROPIC_BASE_URL": "https://…",
      "ANTHROPIC_DEFAULT_SONNET_MODEL": "…"
    },
    "claudeJson": { "optional": "flags merged into ~/.claude.json on switch" }
  }
}
```

Adding a provider is adding an entry — no script changes. The `env`
object is exactly what the provider's "use us with Claude Code" docs tell
you to put in `settings.json`. The optional `claudeJson` object is for
providers whose docs ask you to pre-seed `~/.claude.json` flags (Kimi
Code needs `penguinModeOrgEnabled` / `hasCompletedOnboarding`).

The two bundled examples:

- **Z.ai (GLM)** — API key from z.ai, sent as `ANTHROPIC_AUTH_TOKEN`
  against `https://api.z.ai/api/anthropic`.
- **Kimi Code** — the *subscription* service, not pay-per-token
  platform.kimi.ai/Moonshot (different endpoint, different keys, different
  billing — the keys are not interchangeable). Create a key in the
  [Kimi Code Console](https://www.kimi.com/code/console), sent as
  `ANTHROPIC_API_KEY` against `https://api.kimi.com/coding/`. The example
  uses `k3[1m]` with 1M-token windows, which needs an Allegretto-or-above
  plan; on lower tiers change the model values to `k3-256k` and both
  window vars to `262144`. See
  [their Claude Code page](https://www.kimi.com/code/docs/en/third-party-tools/claude-code.html).

## Safety properties

- **Only touches what it owns.** Switching first removes every env key
  that appears in *any* provider entry, then merges the chosen provider's
  block. Your hooks, permissions, model setting, and anything else in
  `settings.json` are never rewritten. `m claude` = strip only.
- **Atomic.** Changes are written to a temp file and `mv`-ed into place;
  the previous version is kept at `~/.claude/settings.json.bak`.
- **Placeholder guard.** Keys still wrapped in `<>` refuse to activate.
- **Testable without risk.** `M_SETTINGS=<file>` and `M_CLAUDE_JSON=<file>`
  point `m` at copies, so you can rehearse a switch without touching your
  real config (see DOCS.md).

## Troubleshooting

- *Switched but nothing changed* — restart `claude`; running sessions
  keep the env they started with.
- *`unknown provider 'x'`* — the name must be a top-level key of
  `providers.json` (or `claude`). `m` with no arguments lists them.
- *Rolled a bad config* — your previous `settings.json` is at
  `~/.claude/settings.json.bak`.

## License

MIT
