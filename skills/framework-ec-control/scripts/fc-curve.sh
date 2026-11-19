#!/usr/bin/env bash
# fc-curve.sh — apply a named fan curve through the framework-control daemon.
#
#   ./fc-curve.sh --id quiet --name Quiet \
#       --points "35:20,50:30,65:55,80:85,90:100" \
#       --hysteresis 3 --up 5 --down 3 --poll 500
#
#   ./fc-curve.sh ... --dry-run        # print the JSON patch, change nothing
#
# Merges the profile into the existing profile list (profiles are replaced wholesale by the API)
# and activates it. Never touches manual duty unless --mode manual is passed.
set -euo pipefail

id=""; name=""; points="35:20,50:30,65:55,80:85,90:100"
hyst=3; up=5; down=""; poll=500; port="${FC_PORT:-}"; dry=0

while [ $# -gt 0 ]; do
    case "$1" in
        --id) id="$2"; shift 2;;
        --name) name="$2"; shift 2;;
        --points) points="$2"; shift 2;;
        --hysteresis) hyst="$2"; shift 2;;
        --up) up="$2"; shift 2;;
        --down) down="$2"; shift 2;;
        --poll) poll="$2"; shift 2;;
        --port) port="$2"; shift 2;;
        --dry-run) dry=1; shift;;
        -h|--help) sed -n '2,14p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[ -n "$id" ] || id="curve-$(date +%s)"
[ -n "$name" ] || name="$id"

if [ -z "$port" ]; then
    for p in $(ss -ltnH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1:/ {n=split($4,a,":"); print a[n]}' | sort -un); do
        if curl -s -m 0.4 "http://127.0.0.1:${p}/api/health" 2>/dev/null | grep -q '"service_version"'; then
            port="$p"; break
        fi
    done
fi
[ -n "$port" ] || { echo "no framework-control daemon found on loopback (set FC_PORT)" >&2; exit 1; }

FC_ID="$id" FC_NAME="$name" FC_POINTS="$points" FC_HYST="$hyst" FC_UP="$up" FC_DOWN="$down" \
FC_POLL="$poll" FC_PORT="$port" FC_DRY="$dry" python3 - <<'PY'
import json, os, sys, time, urllib.request

port = os.environ["FC_PORT"]
base = f"http://127.0.0.1:{port}"
dry = os.environ["FC_DRY"] == "1"

def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as r:
        return json.load(r)

def post(path, payload):
    req = urllib.request.Request(base + path, data=json.dumps(payload).encode(),
                                 headers={"content-type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)

points = []
for pair in os.environ["FC_POINTS"].split(","):
    pair = pair.strip()
    if not pair:
        continue
    t, d = pair.split(":")
    points.append([int(t), int(d)])
if len(points) < 2:
    sys.exit("need at least two points, e.g. 40:25,70:60")
if any(points[i][0] >= points[i + 1][0] for i in range(len(points) - 1)):
    sys.exit("points must be strictly ascending in temperature")
if any(not 0 <= d <= 100 for _, d in points):
    sys.exit("duty must be 0-100")

curve = {
    "sensors": [],
    "points": points,
    "hysteresis_c": int(os.environ["FC_HYST"]),
    "rate_limit_pct_per_step": int(os.environ["FC_UP"]),
    "poll_ms": int(os.environ["FC_POLL"]),
}
if os.environ["FC_DOWN"].strip():
    curve["rate_limit_down_pct_per_step"] = int(os.environ["FC_DOWN"])

profile = {"id": os.environ["FC_ID"], "name": os.environ["FC_NAME"],
           "mode": "curve", "curve": curve, "overrides": []}

cfg = get("/api/config")
fan = cfg.get("fan") or {}
profiles = [p for p in (fan.get("profiles") or []) if p.get("id") != profile["id"]]
profiles.append(profile)
patch = {"fan": {"profiles": profiles, "active_profile": profile["id"]}}

if dry:
    print(json.dumps(patch, indent=2), flush=True)
    print("--dry-run: nothing sent", file=sys.stderr)
    sys.exit(0)

before = get("/api/thermal")
print(f"before: {before.get('fans')} {before.get('temps')}")
post("/api/config?client_id=fc-curve-script", patch)

back = get("/api/config")
active = ((back.get("fan") or {}).get("active_profile"))
ok = active == profile["id"]
print(f"active_profile now: {active}  ({'ok' if ok else 'MISMATCH — check profiles payload'})")

# Curve is evaluated on the next poll; give it a couple of intervals plus rate-limit steps.
time.sleep(max(2, int(os.environ["FC_POLL"]) / 1000 * 3))
after = get("/api/thermal")
print(f"after:  {after.get('fans')} {after.get('temps')}")
print("RPM must move within ~1-3 s per rate-limit step; duty is the instruction, RPM is the evidence.")
sys.exit(0 if ok else 3)
PY
