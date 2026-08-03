# DOCS — how `m` works and how to build one like it

This is the methodology behind `m`, written so you can audit it, extend
it, or rebuild the same idea for another tool. The whole program is ~120
lines of zsh around `jq`; everything interesting is in the design
decisions, not the code volume.

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

### 1. One data file, zero per-provider code

All providers live in `~/.claude/providers.json`:

```json
{ "<name>": { "label": "…", "env": { … }, "claudeJson": { … } } }
```

The switcher iterates over whatever keys exist. Adding a provider is a
data change; the script never hard-codes a provider name. `claude`
(Anthropic default) is the one reserved name, meaning "no provider env".

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
mv "$tmp" "$SETTINGS"
```

If jq fails (syntax error in providers.json, bad filter), the temp file
is discarded and `settings.json` is untouched. `mv` on the same
filesystem is atomic, so a crash can't leave a half-written config. The
`.bak` is a one-step undo.

### 5. Placeholder guard

The shipped `providers.example.json` wraps unset keys in `<>`. Before
switching, the tool reads the target's credential
(`.ANTHROPIC_AUTH_TOKEN // .ANTHROPIC_API_KEY // ""`) and refuses (exit
3) if it's empty or starts with `<`. This turns "I forgot to paste my
key" from a confusing auth failure inside Claude Code into an immediate,
named error at switch time.

### 6. Provider hooks beyond `env`: the `claudeJson` block

Some providers need one-time flags in `~/.claude.json` (Kimi Code's docs
ship a Node script setting `penguinModeOrgEnabled` and
`hasCompletedOnboarding`). Rather than special-casing, a provider entry
may carry a `claudeJson` object that gets shallow-merged
(`. + $add`, same atomic-write pattern) into `~/.claude.json` on switch.
The merge is additive and idempotent, mirroring the providers' own
scripts, which also never remove the flags. The other half of Kimi's
script — deleting stale `ANTHROPIC_*_MODEL` env entries — is already what
decision 2 does on every switch.

### 7. The picker is cosmetic; the plumbing is scriptable

The arrow-key UI (`read -sk1`, `ESC [ A/B` sequences, redraw with
`\e[NA`/`\e[K`, cursor hidden via `\e[?25l` with a zsh `always` block to
restore it) is a thin layer over `switch_to`. When stdin/stdout are not
TTYs, bare `m` degrades to `status`, so the tool stays usable from
scripts and CI.

## Testing methodology (no risk to your real config)

The file paths are overridable: `M_SETTINGS` and `M_CLAUDE_JSON`. That
makes the whole tool rehearsable against copies:

```bash
cp ~/.claude/settings.json /tmp/s.json
cp ~/.claude.json /tmp/cj.json
export M_SETTINGS=/tmp/s.json M_CLAUDE_JSON=/tmp/cj.json

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

The interactive picker can be exercised headlessly with a pseudo-TTY:

```bash
printf '\033[B\r' | script -q /dev/null m   # down-arrow + return
printf 'q'        | script -q /dev/null m   # quit, no change
```

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
