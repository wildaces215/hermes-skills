# hermes-skills

Agent skills for [Hermes Agent](https://github.com/NousResearch/hermes-agent) — the `SKILL.md` format is
portable, so these also load in Claude Code, Codex-style agents and anything else that reads
`<name>/SKILL.md`.

## Skills

| Skill | What it does |
|---|---|
| [`framework-ec-control`](skills/framework-ec-control/SKILL.md) | Fan curves, charge limits and EC state on Framework Laptop 12/13/16 and Framework Desktop — `framework_tool` + the `framework-control` daemon, the sticky-manual-duty trap, and root-free monitoring via `cros_ec` hwmon. |

## Install

```bash
# whole repo as a skill source (search + install by name)
hermes skills tap add wildaces215/hermes-skills
hermes skills install wildaces215/hermes-skills/framework-ec-control

# or straight from the folder name
hermes skills install wildaces215/hermes-skills/framework-ec-control --category devops
```

Not using Hermes? Copy the skill directory into your agent's skills folder — the only required file is
`SKILL.md`; `references/` and `scripts/` sit next to it.

## What makes a skill worth installing

A skill is only as good as the failure modes it encodes. Each one here is written from reading the
implementation and then exercising it on real hardware:

- **`framework-ec-control`** documents that manual fan duty survives daemon death (no `ExecStop`, no
  watchdog), that the loopback API is unauthenticated and root-owned, that the updater writes to a fixed
  `/tmp` path with no signature check, and that `framework_tool`'s sensor names changed in 0.6.5. It
  ships three scripts: `fc-status.sh` (read-only, no root), `fc-curve.sh` (named curve via the API,
  `--dry-run` supported), `fc-restore-auto.sh` (hands the fan back to firmware in the right order).

## Conventions used here

- `skills/<name>/SKILL.md` — frontmatter carries `name`, a trigger-shaped `description`, `version`,
  `license`, `platforms`, and `metadata.hermes.tags`.
- `references/` — detail loaded on demand (API schemas, hardware quirks, risk model). Kept out of
  `SKILL.md` so the always-loaded part stays small.
- `scripts/` — runnable helpers with `--dry-run` and read-only defaults where destructive behaviour is
  possible.
- Skills state what they verified and when. Claims that depend on a version carry it.

## Licence

MIT. See [LICENSE](LICENSE).
