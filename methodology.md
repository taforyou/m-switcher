# DOCS — how `m` works and how to build one like it

This is the methodology behind `m`, written so you can audit it, extend
it, or rebuild the same idea for another tool. The core is zsh around
`jq`; optional live catalogs and endpoint routing add HTTP orchestration
without changing the strip-then-merge safety model.

## The problem shape

Claude Code selects its backend through environment variables in the
`env` block of `~/.claude/settings.json` (`ANTHROPIC_BASE_URL`,
`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY`, `ANTHROPIC_DEFAULT_*_MODEL`,
…). Every Anthropic-compatible provider publishes "put this env block in
settings.json" instructions. Switching providers by hand means pasting
and deleting JSON in a file that *also* holds your hooks, permissions,
and preferences — easy to botch, annoying to repeat.

So the tool is: a set of named env blocks, and a command that installs
exactly one of them (or none) into `settings.json` without disturbing
anything else.

## Design decisions

### 1. One extensible provider data file

All providers live in `~/.claude/providers.json`:

```json
{ "<name>": { "label": "…", "env": { … }, "claudeJson": { … } } }
```

The switcher iterates over whatever keys exist. A basic provider is only
a data change. `claude` (Anthropic default) is the one reserved name,
meaning "no provider env". Providers may additionally declare a
`modelCatalog` with validation, model, endpoint, and preset API URLs.

### 2. Strip-then-merge, not toggle

The naive design is a per-provider on/off toggle. That breaks the moment
you have two providers: switching zai → kimi must remove zai's keys, and
"off" logic multiplies. Instead every switch is the same two-step,
idempotent operation:

1. Compute the **owned key set** — the union of env keys across *all*
   provider entries:
   `($p[0] | [.[].env | keys[]] | unique)`
2. Delete every owned key from the current `env`, then (unless the target
   is `claude`) merge the target provider's block. Drop `env` entirely if
   it ends up empty.

The full jq filter:

```jq
($p[0] | [.[].env | keys[]] | unique) as $all
| .env = ((.env // {}) | with_entries(.key as $k | select(($all | index($k)) | not)))
| (if $name != "claude" then .env += $p[0][$name].env else . end)
| if .env == {} then del(.env) else . end
```

Consequences worth having:

- Switching is **stateless** — the result depends only on the target,
  never on what was active before. zai → kimi and claude → kimi produce
  identical files.
- User-owned env keys (anything *not* claimed by a provider entry) pass
  through untouched, as does every other top-level setting.
- A provider that uses different key names than another (Z.ai's
  `ANTHROPIC_AUTH_TOKEN` vs Kimi's `ANTHROPIC_API_KEY`) still gets fully
  cleaned up, because the owned set is the union.

One subtle jq bug to avoid: inside `with_entries(select(...))`, bind
`.key` *before* piping into another object (`.key as $k | ($z | has($k))`)
— `$z | has(.key)` rebinds `.` and reads `.key` from the wrong object.

### 3. Active-provider detection is derived, not stored

No state file. The active provider is whichever entry's
`env.ANTHROPIC_BASE_URL` equals the one in `settings.json`; no match (or
no `env`) means `claude`:

```jq
(.env.ANTHROPIC_BASE_URL // "") as $b
| first($p[0] | to_entries[] | select(.value.env.ANTHROPIC_BASE_URL == $b) | .key) // "claude"
```

Stored state can drift from reality (hand-edits, restored backups);
derived state cannot.

### 4. Atomic writes with a backup

Never edit the target in place:

```zsh
tmp="$(mktemp "$SETTINGS.XXXXXX")"
jq … "$SETTINGS" > "$tmp" || { rm -f "$tmp"; return 1; }
cp "$SETTINGS" "$SETTINGS.bak"
chmod 600 "$SETTINGS.bak"
mv "$tmp" "$SETTINGS"
```

If jq fails (syntax error in providers.json, bad filter), the temp file
is discarded and `settings.json` is untouched. `mv` on the same
filesystem is atomic, so a crash can't leave a half-written config. The
`.bak` is a one-step undo.

Two details matter for files that hold API keys. `cp` gives a *new*
backup the source's mode but keeps the mode of an *existing* one, so a
`.bak` created 644 by an earlier version (or from a 644 settings.json,
which is how Claude Code creates it) would stay world-readable forever —
hence the explicit `chmod 600` after every backup, plus `umask 077` at
the top of the script so anything else it creates is private too. And
`mv` over a symlink replaces the link itself, so the three paths are
resolved with zsh's `:A` at startup and dotfiles-managed configs are
written through.

### 5. Placeholder guard

The shipped `providers.example.json` wraps unset keys in `<>`. Before
switching, the tool reads the target's first non-empty Anthropic auth
credential and refuses (exit 3) if it is missing or starts with `<`.
`m key openrouter` reads without terminal echo and validates against the
provider's `validationUrl` before atomically saving it. This turns "I
forgot to paste my key" from a confusing auth failure inside Claude Code
into an immediate, named error at switch time.

### 6. Provider hooks beyond `env`: the `claudeJson` block

Some providers need one-time flags in `~/.claude.json` (Kimi Code's docs
ship a Node script setting `penguinModeOrgEnabled` and
`hasCompletedOnboarding`). Rather than special-casing, a provider entry
may carry a `claudeJson` object that gets shallow-merged
(`. + $add`, same atomic-write pattern with a `.bak`) into
`~/.claude.json` on switch. The merge is prepared and validated *before*
`settings.json` is committed and committed first: a corrupt or non-object
`~/.claude.json` therefore blocks the switch instead of leaving
`settings.json` switched without the flags, and a merge that would change
nothing is skipped. The merge is additive and idempotent, mirroring the
providers' own scripts, which also never remove the flags (so they persist
after switching away). The other half of Kimi's
script — deleting stale `ANTHROPIC_*_MODEL` env entries — is already what
decision 2 does on every switch.

### 7. The picker is cosmetic; the plumbing is scriptable

The arrow-key UI (`read -sk1`, escape sequences parsed byte by byte so
that Left/Home/F-keys/Alt+key are ignored rather than mistaken for cancel,
redraw with `\e[NA`/`\e[K` over lines clipped to the terminal width so
nothing wraps, cursor hidden via `\e[?25l` and the tty kept raw for the
whole picker, both restored by a zsh `always` block on the normal path and
by INT/TERM/HUP/EXIT traps otherwise — `always` does not run when zsh dies
from a signal) is a thin layer over `switch_to`. When stdin/stdout are not
TTYs, bare `m` degrades to `status`, so the tool stays usable from
scripts and CI.

### 8. Live model search and router models

A provider with `modelCatalog.url` can expose live choices. OpenRouter's
catalog URL filters for text-output models advertising `tools`, because
Claude Code is an agent rather than a plain chat client. The picker keeps
the server's ranking when no query is present. Typed input is matched
case-insensitively against the beginning of the model name/ID first, then
as a substring, so one keystroke such as `Q` immediately narrows the list.

Providers that publish no models API ship their lineup statically instead:
`modelCatalog.models` in providers.json holds the same
id/name/context_length/pricing records a live catalog would return, and is
served without a credential or request (the bundled Z.ai GLM entry — Z.ai
has no models endpoint, so its five Claude-Code-capable chat models and
their official context windows travel with the file). When such a provider
also has no `endpointsUrl`, `catalog_switch` routes by model ID alone —
the same direct path router models take — because a first-party gateway
hosts every model itself and there is nothing to pin. The tradeoff is
staleness: static prices and windows change only when the bundled file
does, and the Discounted picker scope reports itself unconfigured.

Catalog `specialModels` add router slugs not returned by the filtered
model endpoint. `openrouter/free` is marked `direct`; it is installed as
the active model without endpoint selection because the router chooses a
compatible free model on every request.

The model picker keeps one search query across three left/right scopes: All,
Discounted, and Free. Free entries are identified by the documented zero
prompt/completion/request prices, the `:free` variant suffix, or the direct
free router. The Models API does not expose provider promotion metadata, so
promotion metadata is loaded when the picker opens from OpenRouter's live
discounted collection and intersected with the tool-capable API catalog. This
decorates promoted rows in All and populates Discounted. A collection failure
leaves All undecorated and disables only the Discounted scope.

Model rows show the catalog's cheapest input/output price per million tokens.
A fixed seven-step ANSI-256 scale runs from green (free) through yellow and
orange to red (at least $30/M combined input/output); keeping fixed thresholds
makes a model's color stable while searching or changing scope. Selection uses
a bold row and marker without replacing the price color. All sorts by combined
input/output price descending, Discounted by promotion percentage descending,
and Free by context length descending. Discounted rows prefix the model name
with the rounded promotion percentage (for example, `[90%]`) so the primary
sorting signal remains visible even when the rest of a row is clipped. Because
the Models API price already includes the promotion, the picker divides it by
`1 - discount` to reconstruct the input/output list price, strikes that price,
and follows it with the current price. The same promotion treatment is used for
discounted entries in All. Match rank remains the primary key while a search
query is active, so prefix matches still precede substring matches.

### 9. Endpoint selection uses live price and discount data

After a concrete OpenRouter model is selected, `m` requests that model's
`/endpoints` resource. It removes unhealthy endpoints and endpoints that
do not advertise `tools`, sorts the remainder by combined prompt and
completion price, and displays the API's `pricing.discount` as a rounded
percentage badge before the provider name, matching discounted model rows.
The first (cheapest) endpoint is highlighted by default.

Endpoint tags—not display names—are load-bearing. A provider such as
StreamLake may publish a specific tag like `streamlake/fp8`; that exact
tag is what OpenRouter accepts in `provider.only`.

### 10. Presets bridge Claude Code to exact OpenRouter routing

Claude Code can set a model through environment variables but cannot add
OpenRouter's `provider` object to every request. `m` therefore creates a
deterministically named OpenRouter preset containing the concrete model
and:

```json
{
  "provider": {
    "only": ["streamlake/fp8"],
    "allow_fallbacks": false
  }
}
```

All Claude Code model-role variables are then set to `@preset/<slug>`.
Before writing a new preset version, `m` retrieves the deterministic slug
and reuses it when the configuration already matches. Selection metadata
uses provider-declared `M_SWITCHER_*` environment keys so `m status` can
show the human-readable model and endpoint without another state file.

The endpoint resource also supplies `context_length`. Generated preset IDs
are unknown to Claude Code, so `m` declares that exact value through
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`. Claude Code applies this variable directly
to an unrecognized custom ID while retaining proactive compaction. This is
safer than disabling unknown-model enforcement and waiting for the gateway to
return a context-length error. Direct routers use their catalog context; the
variable-model `openrouter/free` router is conservatively declared as 200K.
A provider may additionally declare `contextEnv.autoCompact` (Z.ai does):
the same selected window is then written to
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, matching Z.ai's devpack instructions, so
compaction tracks the chosen model instead of a static default.

Claude Code 2.1.233 also emits a separate unknown-model diagnostic. A
`modelOverrides` value suppresses it, but makes Claude Code identify the route
with that Anthropic model's built-in context size. m-switcher therefore adds a
temporary recognition mapping only for exactly representable windows: 200K,
or at least 1M with a `[1m]` suffix (which Claude Code strips before sending
the model ID to OpenRouter). It does not mislabel 128K, 262K, or 512K routes to
silence a cosmetic message. Ownership metadata ensures only m-switcher's own
mapping is updated or removed; a conflicting user mapping wins.

## Testing methodology (no risk to your real config)

The file paths are overridable: `M_SETTINGS`, `M_CLAUDE_JSON`, and
`M_PROVIDERS`. That
makes the whole tool rehearsable against copies:

```bash
cp ~/.claude/settings.json /tmp/s.json
cp ~/.claude.json /tmp/cj.json
export M_SETTINGS=/tmp/s.json M_CLAUDE_JSON=/tmp/cj.json
export M_PROVIDERS=/tmp/providers.json

m zai && m status                 # switch on the copy
jq -S '.env' /tmp/s.json          # inspect exactly what was written
m kimi && m zai                   # cross-switch: no leftovers from kimi
m claude
diff <(jq -S . ~/.claude/settings.json) <(jq -S . /tmp/s.json)   # byte-identical round trip
```

The invariants to assert after any change to the script:

1. **Round trip**: claude → X → claude reproduces the original file
   exactly (compare with `jq -S` to ignore key order).
2. **Cross-switch cleanliness**: X → Y leaves zero keys from X.
3. **Guard**: switching to a `<placeholder>` provider exits 3 and changes
   nothing.
4. **Preservation**: everything outside the owned key set (hooks,
   permissions, unrelated `~/.claude.json` content) survives untouched.
5. **Exact endpoint**: a selected tag is persisted as `provider.only`,
   with fallbacks disabled, and all Claude Code model roles reference the
   resulting preset.
6. **Router bypass**: direct router models such as `openrouter/free`
   never create or select an endpoint preset.
7. **Context accuracy**: an endpoint's advertised context length (or a direct
   router's catalog context) becomes Claude Code's assumed maximum and is
   removed on the round trip back to Claude.
8. **Override ownership**: m-switcher removes only the recognition mapping it
   created and never overwrites a conflicting user-owned `modelOverrides`
   entry.

The interactive picker can be exercised headlessly with a pseudo-TTY:

```bash
printf '\033[B\r' | script -q /dev/null m   # down-arrow + return
printf 'q'        | script -q /dev/null m   # quit, no change
```

The repository's `tests/test_m.zsh` replaces `curl` with a deterministic
fixture server and asserts key validation, search, discount ordering,
preset payloads, free-router bypass, preservation, and round trips.

## Porting notes

- zsh-isms used: `${(f)"$(…)"}` (split lines into an array), `read -sk1`,
  `{ … } always { … }`. A bash port needs `mapfile`, `read -rsn1`, and a
  `trap`-based cursor restore.
- Everything JSON goes through `jq`; there is no hand-rolled parsing, and
  that's load-bearing — `settings.json` may contain arbitrary user
  config, and regex-editing it is how configs get eaten.
- The same pattern (owned-key strip-then-merge + derived state + atomic
  writes) ports to any tool configured by an env-block-in-JSON:
  the switcher is Claude Code-specific only in its file paths and the
  reserved `claude` name.
