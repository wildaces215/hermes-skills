#!/usr/bin/env bash
# fc-restore-auto.sh — hand fan control back to the EC firmware, in the right order.
#
#   ./fc-restore-auto.sh            # show what it will do, then run it
#   ./fc-restore-auto.sh --dry-run  # only show
#   ./fc-restore-auto.sh --stop-service   # also stop the daemon (needed if it is in manual mode)
#
# Why the order matters: while the daemon is running and its active profile is "manual", it re-applies
# the duty within one poll interval, so a bare `framework_tool --autofanctrl` is undone in <1 s.
set -uo pipefail

dry=0; stop=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1; shift;;
        --stop-service) stop=1; shift;;
        -h|--help) sed -n '2,11p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

port=""
for p in $(ss -ltnH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1:/ {n=split($4,a,":"); print a[n]}' | sort -un); do
    if curl -s -m 0.4 "http://127.0.0.1:${p}/api/health" 2>/dev/null | grep -q '"service_version"'; then
        port="$p"; break
    fi
done

mode=""; state=""
state="$(systemctl is-active framework-control 2>/dev/null || true)"
if [ -n "$port" ]; then
    mode="$(curl -s -m 3 "http://127.0.0.1:${port}/api/config" | python3 -c '
import json,sys
c=json.load(sys.stdin); fan=c.get("fan") or {}
a=fan.get("active_profile")
p=next((x for x in (fan.get("profiles") or []) if x.get("id")==a), {})
print(p.get("mode",""))' 2>/dev/null)"
fi

echo "daemon:  ${state:-unknown}${port:+ on port $port}"
echo "mode:    ${mode:-unknown}"
echo

cmds=()
if [ "$state" = "active" ] && [ "$mode" = "manual" ]; then
    if [ "$stop" = "1" ]; then
        echo "daemon is active in manual mode -> stopping it will NOT restore firmware control by itself;"
        echo "autofanctrl must follow (that is what this script does)."
        cmds+=("sudo systemctl stop framework-control")
    else
        echo "NOTE: daemon is active in manual mode and will re-apply its duty within one poll interval."
        echo "      Pass --stop-service to stop it first, or switch the profile to a curve/disabled in the UI."
    fi
fi
cmds+=("sudo framework_tool --autofanctrl")

printf 'run:\n'
for c in "${cmds[@]}"; do printf '  %s\n' "$c"; done

if [ "$dry" = "1" ]; then
    echo
    echo "--dry-run: nothing executed"
    exit 0
fi

for c in "${cmds[@]}"; do
    echo
    echo "> $c"
    if ! eval "$c"; then
        echo "failed: $c" >&2
        exit 1
    fi
done

echo
echo "done. Verify with: ./fc-status.sh   (fan should follow the firmware curve again)"
echo "If you stopped the daemon and want it back:"
echo "  sudo systemctl start framework-control   # and make sure the active profile is curve/disabled"
