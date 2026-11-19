# Safety and risk model

Everything below is from reading framework-control 0.5.5 (commit b29db73) and framework_tool 0.6.7, and
from exercising both on a Framework Laptop 13 (AMD Ryzen AI 300). Line numbers refer to
`service/src/**` in that release.

## 1. Manual duty outlives the daemon (the one that cooks hardware)

- `main.rs` has no shutdown hook; `poem::Server` shuts down connections, not the EC.
- The shipped unit is `Type=simple`, `Restart=on-failure`, `RestartSec=5` — no `ExecStop`,
  no `ExecStopPost`, no `WatchdogSec`.
- The fan task only calls `autofanctrl()` when the *mode* changes to `Disabled`, when the fan panel is
  disabled, or when no manual duty is configured (`tasks/fan_curve.rs:86,111`). Process death is not a
  mode, so nothing reverts.
- The EC latches `--fansetduty` until it receives `--autofanctrl` or the machine resets.

Consequences to design around:
- `systemctl stop framework-control` in Manual 47 % leaves the fan at 47 % at 95 °C.
- An OOM kill, a panic, or an update-induced restart has the same effect.
- Mitigation: the `ExecStopPost` drop-in in the SKILL.md procedure, plus "never end a session in Manual".

## 2. The API is root-level and unauthenticated

- No auth middleware anywhere in `routes.rs` (no bearer, no token, no session).
- Bound to `127.0.0.1`, so only local processes — but that includes every unprivileged user, every
  script, and every browser page that can be tricked into a non-preflighted request.
- CORS is real: `Cors::new().allow_origin(self_origins + FRAMEWORK_CONTROL_ALLOWED_ORIGINS)`,
  `allow_methods([GET,POST,OPTIONS])`, `allow_headers(["content-type"])`. Verified empirically: a foreign
  `Origin` gets no `Access-Control-Allow-Origin`, the self-origin does. `POST /api/config` needs
  `content-type: application/json`, which is not a CORS-simple type, so cross-origin writes require a
  preflight and are blocked. Drive-by web CSRF is therefore impractical; local-process abuse is not.
- Practical rule: treat `POST /api/config` and `POST /api/update/apply` as root actions. On a shared
  machine, firewall the port for other users or run the daemon under a dedicated uid with an EC-capable
  group (out of scope for the stock unit).

## 3. Update path: predictable temp dir, no verification

`update.rs` (Linux branch):
1. `std::env::temp_dir().join("framework-control-update")` — a **fixed** path created and written as root.
2. Downloads a `.tar.gz` from the GitHub release of `FRAMEWORK_CONTROL_UPDATE_REPO` (defaults to the
   upstream repo) with `reqwest` + rustls (TLS verified, nothing else).
3. Extracts with the system `tar` (`Command::new("tar")`) into that dir.
4. Copies `framework-control` over the running binary as `framework-control.new`, renames atomically, then
   spawns `systemctl restart framework-control` after a 2 s sleep.

Risks:
- No checksum, no signature. Releases publish `SHA256SUMS` since 0.5.5, but neither the installer
  (`install-linux.sh`) nor the updater reads it. A compromised release, a compromised maintainer token, or
  a compromised registry path means root code execution.
- `CWE-377`-class: the fixed `/tmp` path can be pre-created by a local user before root touches it. The
  AUR unit sets `PrivateTmp=yes` which neutralises this; the install-script unit does **not**.
- The updater restarts the service itself, so "manual restart required" logging applies only when the
  `systemctl` call fails.

Recommendation: leave auto-update off; update deliberately, download the artifact yourself, verify
`SHA256SUMS` from the release page, then restart. If you want to harden the unit, add `PrivateTmp=yes`
*and* keep the updater in mind (it will then use the service's private /tmp, which is fine).

## 4. Service hardening is absent

No `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`, `CapabilityBoundingSet`,
`SystemCallFilter`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies`. A root daemon that parses text
from an external binary, downloads code, and writes sysfs is exactly the case those directives exist for.
A conservative hardening drop-in:

```ini
[Service]
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/etc/framework-control /sys/devices/system/cpu /usr/local/bin
NoNewPrivileges=yes
```

Test `ProtectSystem=strict` against the updater before trusting it in production — it will refuse the
binary replacement otherwise.

## 5. Parser coupling and control-loop edge cases

- Telemetry is regex-parsed CLI stdout (`cli/framework_tool_parser.rs`, ~500 LOC). Guarded by unit tests
  and the pinned-version switch, but a CLI format change is a real failure mode.
- Curve validation is shallow: profile ids and auto-switch references are checked; curve point ordering,
  duty range, and `duty_pct` floors are not (`types.rs:115`). The clamp to 100 happens at apply time;
  nothing clamps to a minimum.
- `sensors: []` means "max of all reported sensors", not "none".
- Two daemons on one machine fight over the same EC. Never run a second instance to test configs; POST to
  the installed one, or stop the real one first.

## What is safe to automate

| Action | Safe to run unattended? |
|---|---|
| `GET` anything on the API; hwmon reads; `--thermal`, `--versions`, `--features` | yes |
| `POST /api/config` changing fan mode/curve, charge limit, theme | yes, with a read-back |
| `framework_tool --fansetduty` | only paired with a guaranteed `--autofanctrl` |
| `systemctl restart framework-control` (manual mode!) | no — the EC keeps the duty through the restart |
| `POST /api/update/apply` | no |
| `--flash-*`, `--stm32-kbd-erase`, `--pd-reset`, `--thermalset` | never automated |
