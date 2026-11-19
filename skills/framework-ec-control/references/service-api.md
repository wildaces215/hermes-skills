# framework-control service API

Loopback-only HTTP API. No authentication of any kind — any local process can read and write it.
CORS allows only the service's own origin plus `FRAMEWORK_CONTROL_ALLOWED_ORIGINS` (verified: a foreign
`Origin` gets no `Access-Control-Allow-Origin` header, the self-origin does).

Base: `http://127.0.0.1:<port>` where the port is baked into the binary at compile time
(`FRAMEWORK_CONTROL_PORT`, `option_env!` fallback). Find it in
`journalctl -u framework-control | grep listening`, or probe `/api/health`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | `{cli_present, service_version}` — the cheapest liveness check |
| GET | `/api/thermal` | `{fans:[{name,rpm}], temps:{sensor:°C}}` |
| GET | `/api/thermal/history` | recent telemetry samples (temp + RPM), background task |
| GET | `/api/battery/history?since=<unix_ms>` | charge % and signed pack watts |
| GET | `/api/power` | battery + charger telemetry, charge-limit info, `power_control` capabilities and `current_state` |
| GET | `/api/versions` | `mainboard_type`, `uefi_version`, `uefi_release_date`, `ec_build_version`, `ec_current_image`, `tool_version` |
| GET | `/api/system` | CPU, memory, OS, dGPU names |
| GET | `/api/config` | whole persisted config |
| POST | `/api/config` | partial config merge (`client_id` query param optional) |
| GET | `/api/config/events` | SSE stream of config changes; keeps the UI in sync across clients |
| GET | `/api/update/check` | current vs latest release |
| POST | `/api/update/apply` | download, replace the running binary, self-restart (Linux) |
| GET | `/api/framework_tool/versions` | available `framework_tool` releases |
| POST | `/api/framework_tool/switch` | pin/downgrade the CLI version |
| POST | `/api/ryzenadj/install`, `/api/ryzenadj/uninstall` | Windows TDP helper |
| GET | `/api/logs` | journald / installer log tail |
| GET/POST | `/api/shortcuts/status`, `/api/shortcuts/create` | desktop entries |

## Config schema

Persisted at `/etc/framework-control/config.json` (Linux) or
`C:\ProgramData\FrameworkControl\config.json` (Windows); override with `FRAMEWORK_CONTROL_CONFIG`.

```jsonc
{
  "version": 2,
  "fan": {
    "profiles": [{
      "id": "quiet",                 // stable id, referenced by active_profile / auto_switch
      "name": "Quiet",
      "mode": "curve",               // "disabled" | "manual" | "curve"
      "manual": { "duty_pct": 47 },  // mode=manual, clamped to 100, NOT floored
      "curve": {
        "sensors": [],               // [] = max over every reported sensor
        "points": [[35,20],[50,30]], // [temp°C, duty%], ascending temp
        "hysteresis_c": 3,           // °C band before a duty reduction is accepted
        "rate_limit_pct_per_step": 5,
        "rate_limit_down_pct_per_step": 3,  // optional, defaults to the up limit
        "poll_ms": 500               // default 2000
      },
      "overrides": [{ "index": 0, "manual": {...} , "curve": {...} }]  // per-fan, optional
    }],
    "active_profile": "quiet",
    "auto_switch": { "ac": "loud", "battery": "quiet" },   // by power source
    "calibration": { /* one-time RPM↔duty mapping from the calibration wizard */ }
  },
  "power": {
    "ac":      { "epp_preference": {"enabled":true,"value":"performance"},
                 "governor": {"enabled":false,"value":"powersave"},
                 "min_freq_mhz": {"enabled":false,"value":400},
                 "max_freq_mhz": {"enabled":false,"value":4000},
                 "tdp_watts": {...}, "thermal_limit_c": {...} },   // Windows: RyzenAdj
    "battery": { /* same shape */ }
  },
  "battery": {
    "charge_limit_max_pct": {"enabled": true, "value": 80},     // 25-100
    "charge_rate_c": {"enabled": false, "value": 0.5},          // 0.05-1.0 C
    "charge_rate_soc_threshold_pct": 90,                        // optional
    "poll_ms": 15000                                            // clamped 5000-60000
  },
  "telemetry": { "poll_ms": 2000 },
  "updates":   { /* auto-check / auto-install preferences */ },
  "ui":        { "theme": "dracula", "panels": [{"id":"fan","enabled":true}],
                 "announcements": {"disabled": false, "seen_date": "2026-10-15"} },
  "framework_tool": { "latest": true }   // false = pinned version
}
```

`Setting*` wrappers (`{"enabled":bool,"value":T}`) exist so a value can be remembered while disabled —
the background task only applies entries with `enabled: true`.

### Patch semantics

`POST /api/config` takes `PartialConfig`: top-level keys `fan`, `power`, `battery`, `updates`,
`telemetry`, `ui`. Within `fan`, `profiles` and `auto_switch` are **replaced wholesale** (send the full
list, not a diff); `active_profile` is a scalar switch. So "add a profile" means GET, append, POST.

Rejected patches return 502 with `{"code":"save_failed"}` and leave the file untouched —
validation covers duplicate profile ids, unknown `active_profile`, and auto-switch entries pointing at a
profile that does not exist. It does **not** validate curve point ranges, ordering, or duty floors.

### Config write amplification

Every accepted POST rewrites the whole JSON and logs one `set_config applied successfully` line. A UI
session dragging sliders produces a write per interaction (observed ~1/s). Harmless at 807 bytes, but
don't script a tight loop of POSTs.

## Notes on reads

- `/api/thermal` is cached ~1 s and `/api/power` ~5 s (the service shells out to `framework_tool`, which
  is not free). Poll no faster than that.
- Sensor names come from `framework_tool --thermal` and are **version-dependent**. Treat them as opaque
  keys, and prefer `sensors: []` (max of all) unless you have a reason to pick.
- `fan1_fault` / `temp*_fault` exist in hwmon; the API does not surface them. If the API shows a fan at
  0 RPM, confirm with hwmon before believing it.
