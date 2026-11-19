#!/usr/bin/env bash
# fc-status.sh — read-only Framework EC/daemon status. Needs no root.
#
#   ./fc-status.sh            # auto-discover the daemon port
#   FC_PORT=30912 ./fc-status.sh
#
# Exit codes: 0 = daemon found, 1 = no daemon (hwmon-only report is still printed).
set -uo pipefail

port="${FC_PORT:-}"

# Listeners on loopback only. `ss` without root cannot show PIDs, so probe /api/health instead.
if [ -z "$port" ]; then
    for p in $(ss -ltnH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1:/ {n=split($4,a,":"); print a[n]}' | sort -un); do
        if curl -s -m 0.4 "http://127.0.0.1:${p}/api/health" 2>/dev/null | grep -q '"service_version"'; then
            port="$p"; break
        fi
    done
fi

echo "== service =="
if systemctl list-unit-files framework-control.service >/dev/null 2>&1; then
    printf 'unit:   %s\n' "$(systemctl is-enabled framework-control 2>/dev/null || echo unknown)"
    printf 'state:  %s\n' "$(systemctl is-active framework-control 2>/dev/null || true)"
else
    echo "unit:   framework-control.service not installed"
fi
echo "port:   ${port:-NOT FOUND (no loopback listener answered /api/health)}"
echo

if [ -n "$port" ]; then
    FC_PORT="$port" FC_UNIT_STATE="$(systemctl is-active framework-control 2>/dev/null || true)" python3 - <<'PY'
import json, os, urllib.request

def env(name, default=""):
    value = os.environ.get(name)
    return default if value in (None, "") else value

base = "http://127.0.0.1:" + env("FC_PORT")

def get(path):
    try:
        with urllib.request.urlopen(base + path, timeout=5) as r:
            return json.load(r)
    except Exception:
        return None

print("== firmware / versions ==")
v = get("/api/versions")
if v:
    for k in ("mainboard_type", "uefi_version", "uefi_release_date", "ec_build_version",
              "ec_current_image", "tool_version"):
        if v.get(k):
            print("  {:<18}{}".format(k, v[k]))
else:
    print("  unavailable")
print()

print("== thermal (daemon) ==")
t = get("/api/thermal")
if t:
    temps = t.get("temps") or {}
    if temps:
        print("  temps: " + ", ".join("{}={}C".format(k, x) for k, x in sorted(temps.items())))
    fans = t.get("fans") or []
    for fan in fans:
        print("  fan:   {} = {} RPM".format(fan.get("name"), fan.get("rpm")))
    if not fans:
        print("  fan:   none reported")
else:
    print("  unavailable")
print()

print("== fan config ==")
mode = ""
cfg = get("/api/config")
if cfg:
    fan_cfg = cfg.get("fan") or {}
    active = fan_cfg.get("active_profile")
    prof = next((p for p in (fan_cfg.get("profiles") or []) if p.get("id") == active), None)
    if not prof:
        print("  active profile {} missing from profiles list".format(active))
    else:
        mode = prof.get("mode", "")
        print("  active profile:    {} ({})".format(active, prof.get("name", "")))
        print("  mode:              {}".format(mode))
        manual = prof.get("manual") or {}
        if manual:
            print("  manual duty:       {}%".format(manual.get("duty_pct")))
        curve = prof.get("curve") or {}
        if curve:
            pts = ", ".join("{}C:{}%".format(p[0], p[1]) for p in (curve.get("points") or []))
            down = curve.get("rate_limit_down_pct_per_step")
            print("  curve points:      [{}]  (+ implicit 0C:0% and 100C:100%)".format(pts))
            print("  hysteresis/limits: {}C, +{}/step up, {}/step down, poll {}ms".format(
                curve.get("hysteresis_c"),
                curve.get("rate_limit_pct_per_step"),
                down if down is not None else curve.get("rate_limit_pct_per_step"),
                curve.get("poll_ms")))
        if prof.get("overrides"):
            print("  per-fan overrides: {}".format(len(prof.get("overrides"))))
    if fan_cfg.get("auto_switch"):
        print("  auto_switch:       {}".format(json.dumps(fan_cfg.get("auto_switch"))))
else:
    print("  unavailable")

if mode == "manual":
    active_unit = env("FC_UNIT_STATE")
    print()
    if active_unit != "active":
        print("!! WARNING: manual duty is configured and the daemon is NOT active.")
        print("   The EC keeps the last duty indefinitely. Run: sudo framework_tool --autofanctrl")
    else:
        print("!! NOTE: manual mode pins the fan at a fixed duty regardless of temperature.")
        print("   Prefer a curve, and never leave manual mode active while stopping the daemon.")
PY
    echo
fi

echo "== thermal (cros_ec hwmon, root-free) =="
ec=""
for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "cros_ec" ] && ec="$d"
done
if [ -n "$ec" ]; then
    echo "node:   $ec"
    [ -r "$ec/fan1_input" ] && printf 'fan1:   %s RPM\n' "$(cat "$ec/fan1_input")"
    for t in "$ec"/temp*_input; do
        [ -r "$t" ] || continue
        raw="$(cat "$t" 2>/dev/null)" || continue
        label="$(cat "${t%_input}_label" 2>/dev/null || basename "$t" _input)"
        if [ "$raw" = "No data available" ]; then
            printf '  %-22s n/a\n' "$label"
            continue
        fi
        crit="$(cat "${t%_input}_crit" 2>/dev/null || echo)"
        if [ -n "$crit" ] && [ "$crit" != "No data available" ]; then
            printf '  %-22s %sC  (crit %sC)\n' "$label" "$((raw / 1000))" "$((crit / 1000))"
        else
            printf '  %-22s %sC\n' "$label" "$((raw / 1000))"
        fi
    done
else
    echo "  cros_ec hwmon not present (cros_ec_lpcs not loaded?)"
fi

[ -n "$port" ]
