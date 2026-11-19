---
name: framework-ec-control
description: "Use when tuning fans, charge limits, or EC state on Framework laptops — framework_tool plus the framework-control daemon, the sticky-manual-duty trap, and root-free monitoring paths."
version: 1.0.0
author: wildaces215
license: MIT
platforms: [linux, windows]
metadata:
  hermes:
    tags: [hardware, framework-laptop, fan-control, ec, thermal, battery, systemd, framework-control]
---

# Framework laptop EC control

Fan duty, charge limits and power profiles on Framework Laptop 12 / 13 / 16 and Framework Desktop.
One embedded controller, three ways to reach it — pick the lowest one that does the job.

| Surface | Root needed | Use for |
|---|---|---|
| `cros_ec` hwmon sysfs (`/sys/class/hwmon/hwmonN`) | **no** | read-only temps and RPM; the default for monitoring and for any check |
| `framework_tool` (FrameworkComputer/framework-system) | yes | one-shot EC read/write: `--thermal`, `--versions`, `--fansetduty`, `--autofanctrl`, `--charge-limit` |
| `framework-control` daemon (Rust, systemd, loopback HTTP + Svelte UI) | daemon runs as root | curves with hysteresis/rate-limit, named profiles, history, battery/power panels |

If a question is "is the fan spinning?" answer it from hwmon. Only escalate to a root surface when the
answer requires a *write*.

## Non-negotiable safety rules

1. **Manual duty is sticky.** The EC keeps the last `--fansetduty` value after the process exits, after
   `systemctl stop`, and after a crash — the shipped unit has no `ExecStop` and no watchdog, and the
   daemon never calls `--autofanctrl` on shutdown. Manual mode + stopped daemon = fan pinned at that
   duty at any temperature.
   Always close a manual session with `sudo framework_tool --autofanctrl`, or leave the daemon in a
   Curve/Disabled profile. `scripts/fc-restore-auto.sh` does it in the right order.
2. **Never set duty 0 as a "quiet" experiment.** `duty_pct` is clamped to `min(100)` and never floored,
   so 0 is a legal, silent, heat-producing configuration.
3. **Curve beats Manual for anything longer than a test.** Manual is a constant; Curve re-evaluates every
   `poll_ms` (default 2000, 500 in the UI), honours hysteresis and per-step rate limits, and falls back
   to the maximum sensor temperature when the configured sensor names stop existing (they did in
   framework_tool 0.6.5).
4. **Read back before declaring success.** `GET /api/config` is the source of truth, not the UI, and not
   the value you just POSTed. Then read `/api/thermal` — duty is an instruction, RPM is evidence.
5. **Do not enable auto-update on a machine you care about.** The updater copies a downloaded binary over
   the running root binary and self-restarts, with no signature or checksum verification. See
   `references/safety-and-risk.md`.

## Quick reference

```bash
# --- monitoring, no root, no daemon ---
ls /sys/class/hwmon/ | xargs -I{} sh -c 'echo "{}: $(cat /sys/class/hwmon/{}/name)"' | grep cros_ec
cat /sys/class/hwmon/hwmon13/fan1_input          # RPM
cat /sys/class/hwmon/hwmon13/temp2_input         # millidegrees
cat /sys/class/hwmon/hwmon13/temp2_crit          # per-sensor critical threshold

# --- EC via CLI (root) ---
sudo framework_tool --thermal                    # temps + fan RPM
sudo framework_tool --versions                   # BIOS / EC / PD firmware, mainboard type
sudo framework_tool --features                   # what this EC firmware supports
sudo framework_tool --fansetduty 60              # 0-100 %, sticky until autofanctrl
sudo framework_tool --autofanctrl                # hand control back to firmware
sudo framework_tool --charge-limit               # get (25-100 %)
sudo framework_tool --charge-limit 80            # set max charge %

# --- daemon ---
systemctl status framework-control --no-pager
journalctl -u framework-control -n 5 --no-pager | grep listening   # the port is baked at build time
curl -s http://127.0.0.1:<port>/api/health
curl -s http://127.0.0.1:<port>/api/thermal
curl -s http://127.0.0.1:<port>/api/config
```

Port discovery matters: `FRAMEWORK_CONTROL_PORT` is required at **compile** time (`option_env!`), so the
port is baked into the binary (30912 for AUR builds, 8090 in dev) and cannot be changed by editing the
unit. `scripts/fc-status.sh` finds it by probing loopback listeners for `/api/health`.

## Procedure — apply a fan curve (daemon path)

1. Confirm the daemon answers: `scripts/fc-status.sh` (also prints current mode and RPM).
2. Choose a curve. Anchors are implicit: the curve always gets `[0,0]` and `[100,100]` wrapped around your
   points, and interpolation is linear. A sane laptop curve:

   | temp °C | duty % |
   |---|---|
   | 35 | 20 |
   | 50 | 30 |
   | 65 | 55 |
   | 80 | 85 |
   | 90 | 100 |

   Keep a floor point (the 35 °C row) — the implicit `[0,0]` anchor means anything below your first point
   ramps duty down toward zero.
3. Apply it — `scripts/fc-curve.sh` merges a named profile into the existing profile list and activates it:

   ```bash
   scripts/fc-curve.sh --id quiet --name Quiet \
     --points "35:20,50:30,65:55,80:85,90:100" \
     --hysteresis 3 --up 5 --down 3 --poll 500
   ```
4. Verify: watch `/api/thermal` for 30 s under load. Duty must move in ≤ `rate_limit_pct_per_step`
   steps and RPM must follow. If the fan never changes, the profile is not active (`GET /api/config`
   → `fan.active_profile`) or the panel is disabled in the UI config.

Full field reference, defaults and the whole REST surface: `references/service-api.md`.

## Procedure — charge limit and power profile

```bash
# charge limit through the EC (persists on the EC; 25-100 %)
sudo framework_tool --charge-limit 80

# through the daemon instead, so it survives reboots and shows in the UI
curl -s -X POST http://127.0.0.1:<port>/api/config \
  -H 'content-type: application/json' \
  -d '{"battery":{"charge_limit_max_pct":{"enabled":true,"value":80}}}'
```

Power on Linux is **not** EC: the daemon writes `scaling_governor`, `energy_performance_preference`
and cpufreq min/max under `/sys/devices/system/cpu/`. Separate AC and battery profiles are reapplied in
the background by a task, so "the governor reverted" usually means the task re-applied the stored
profile — change the config, not sysfs. On Windows the same panel drives RyzenAdj (TDP + thermal limit).

## Procedure — make the daemon crash-safe

Root-cause of the sticky-duty trap is a missing `ExecStopPost`. One drop-in closes it:

```bash
sudo install -d /etc/systemd/system/framework-control.service.d
sudo tee /etc/systemd/system/framework-control.service.d/safety.conf >/dev/null <<'EOF'
[Service]
ExecStopPost=/usr/bin/framework_tool --autofanctrl
EOF
sudo systemctl daemon-reload && sudo systemctl restart framework-control
```

Verify with `systemctl show framework-control -p ExecStopPost` and by confirming RPM drops to the
firmware curve after a `systemctl stop`. `references/safety-and-risk.md` has the reasoning and the
remaining risks (unauthenticated loopback API, unsigned self-update, absent sandboxing).

## Verification checklist

- `scripts/fc-status.sh` exits 0 and prints mode + RPM.
- After a mode change, `GET /api/config` returns the new `fan.active_profile` **and** the profile body you
  intended (profiles are replaced wholesale by the API, not merged field-by-field).
- RPM moved in the expected direction within ~5 s of a duty change; temps stable or falling.
- After any manual duty test: `sudo framework_tool --autofanctrl` ran, and RPM is back on the firmware curve.
- `systemctl show framework-control -p ExecStopPost` is non-empty if you added the drop-in.

## Pitfalls

- **Two daemons, one EC.** Do not start a second `framework-control` instance to "test" a config — its fan
  task writes the same EC and fights the real one. Test writes through the installed daemon.
- **Sensor names drift between framework_tool versions.** `cpu_f75303@4d` / `ddr_f75303@4d` /
  `local_f75303@4d` on Ryzen AI 300; older names like `cpu@4c` disappear. A curve pinned to stale names
  now falls back to "max of all sensors" — louder, but not stuck.
- **`sensors: []` means "max over every reported sensor"**, including DDR. Name sensors explicitly if you
  want the fan to ignore a hot DIMM or a dGPU that is powered down.
- **Poll intervals are clamped, not honoured blindly:** battery history 5 s–60 s, telemetry default 2 s,
  curve `poll_ms` default 2000 (the UI uses 500).
- **`framework_tool` needs root on Linux** (`/dev/cros_ec` is `crw------- root:root`); on Windows it needs
  elevation. A "permission denied" from the CLI is not a hardware fault.
- **The shipped systemd unit has no hardening** (`Type=simple`, `Restart=on-failure` only). If you add
  `PrivateTmp=yes`, do it deliberately — the updater relies on `/tmp/framework-control-update`.
- **Windows EC control wants BIOS ≥ 3.07 on Laptop 16**; older firmware ignores fan writes.

## References

- `references/service-api.md` — every endpoint, the config schema with types/defaults/units, patch semantics.
- `references/ec-and-hwmon.md` — `framework_tool` flag map, hwmon nodes, per-platform sensor sets, EC sentinels.
- `references/safety-and-risk.md` — why manual duty is sticky, what the loopback API exposes, update-path risks.
- `scripts/fc-status.sh`, `scripts/fc-curve.sh`, `scripts/fc-restore-auto.sh` — runnable helpers.
