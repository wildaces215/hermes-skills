# EC surfaces: framework_tool, hwmon, and platform quirks

## framework_tool (root)

The official CLI from FrameworkComputer/framework-system. Everything EC-related the daemon does goes
through it; use it directly when you do not need the daemon's curve engine.

```bash
framework_tool --versions        # BIOS/EC/PD versions, mainboard_type, RO|RW EC image
framework_tool --features        # bitmask of EC features this firmware supports
framework_tool --thermal         # temps + fan RPM
framework_tool --thermalget      # temperature thresholds per sensor
framework_tool --power -vv       # battery/AC detail (what the power panel parses)
framework_tool --fansetduty 40   # 0-100 %, or "1 40" for fan index 1
framework_tool --fansetrpm 3000  # duty by RPM target, limited by the EC fan table
framework_tool --autofanctrl     # return to firmware control — the exit that matters
framework_tool --charge-limit [25-100]
framework_tool --charge-rate-limit <C> [soc_threshold]
framework_tool --kblight <pct> | --kblight
framework_tool --fp-led-level <high|medium|low|ultra-low|auto>
framework_tool --inputdeck [--inputdeck-mode auto|off|on|reset]
framework_tool --privacy        # camera/mic kill switches
framework_tool --info           # SMBIOS
```

Elevation: on Linux `/dev/cros_ec` is `crw------- root:root`, so the CLI needs root. On Windows it needs
an elevated console. Root is only needed for EC access — argument parsing and `--help` do not.

EC-write flags beyond fans (`--flash-*`, `--stm32-kbd-erase`, `--pd-reset`, `--thermalset`) are the kind
of thing that can leave hardware unbootable or the keyboard dead. Never call them as part of an
automated fix-up.

## hwmon (no root, read-only)

`cros_ec_lpcs` registers the EC as a hwmon device. Reading it needs nothing and changes nothing:

```
/sys/class/hwmon/hwmonN/
  fan1_input      RPM
  fan1_target     last requested target (read-only exposure)
  fan1_fault
  temp1_input     millidegrees
  temp1_label     "local_f75303@4d"
  temp1_crit      90000
  temp1_max temp1_emergency temp1_fault
  power
```

Find the right index instead of hardcoding it:

```bash
for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name)" = cros_ec ] && echo "$d"; done
```

Ryzen AI 300 (Laptop 13) sensor set, verified: `local_f75303@4d` (crit 90 °C), `cpu_f75303@4d`
(crit 98 °C), `ddr_f75303@4d` (crit 80 °C), plus `cpu@4c` which returns "No data available" — the
daemon consequently reports three temperatures, not four. Other sensors worth knowing:
`k10temp` (Tctl/Tdie), `amdgpu` (edge/junction), `acpitz`, `BAT1`, `nvme`, `spd5118` (DIMM).

Note `ddr_f75303@4d` has the *lowest* critical threshold of the three (80 °C). With `sensors: []` a DDR
sensor reading drives the curve, which is normally what you want on a memory-heat-limited laptop but
explains unexpected ramp-ups under load.

## EC sentinels and parsing

- Fan speed sentinels: `0xFFFE` (stalled) and `0xFFFF` are not real RPM. The daemon maps a stalled fan to
  `0` RPM instead of the bogus 65534 the CLI would print.
- Sensor names changed in framework_tool 0.6.5 (`cpu@4c` → `*_f75303@4d` style). The daemon's fallback:
  if none of a curve's configured sensors exist, use the max of the sensors that do exist.
  Do not write a curve against hardcoded sensor names without that fallback in mind.
- The daemon parses CLI **stdout with regexes**, so a framework_tool version bump can break telemetry.
  That is why the Settings panel can pin a specific `framework_tool` release
  (`POST /api/framework_tool/switch`). If telemetry goes blank after an update, pin the previous CLI
  version rather than assuming hardware failure.

## Platform notes

- **Laptop 16**: BIOS ≥ 3.07 required for correct EC/fan behaviour. Below that, fan writes appear to be
  ignored. Two fans — per-fan overrides (`fan.profiles[].overrides[]`) exist for this.
- **Laptop 12**: STM32 keyboard controller (`--stm32-kbd-*`); input deck modes.
- **Laptop 13 (AMD Ryzen AI 300)**: one "APU Fan", three usable temp sensors, `--versions` reports board
  `Laptop 13 (AMD Ryzen AI 300 Series)`, EC image `RO` under normal operation (`RW` means it fell back
  after a failed update).
- **Framework Desktop**: same daemon, `mainboard_type` says Desktop; fan control is per-fan.
- **Windows**: EC path identical through `framework_tool.exe`; power control switches to RyzenAdj, which
  the daemon installs/uninstalls on demand (`/api/ryzenadj/*`).

## Calibration

The UI's calibration wizard measures RPM↔duty so the curve editor can show an estimated duty for the
current RPM. It is stored in `fan.calibration` and is purely cosmetic for control purposes — an
uncalibrated machine still controls fans correctly, it just cannot draw the RPM overlay.
