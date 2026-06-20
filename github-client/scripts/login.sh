#!/usr/bin/env bash
# gh-skills — OAuth device-flow login.
#
# Logs the user into GitHub and caches the resulting token (with its expiry) at
# ${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills/token.json. No client secret is used.
#
#   GITHUB_OAUTH_CLIENT_ID   override the OAuth App client id (defaults to gh-skills's)
#   GH_SKILL_SCOPE           OAuth scopes to request (default: "repo")
#
# Requires: curl, python3.
set -euo pipefail

CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-Ov23liz5y2IEXIhpeOJk}"
SCOPE="${GH_SKILL_SCOPE:-repo}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills"
TOKEN_FILE="$CONFIG_DIR/token.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need curl; need python3

# Extract one top-level field from JSON on stdin (empty string if absent).
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
print("" if v is None else v)
' "$1"
}

echo "Requesting device code (client ${CLIENT_ID}, scope: ${SCOPE})..."
dc=$(curl -sS -X POST https://github.com/login/device/code \
  -H "Accept: application/json" \
  -d "client_id=${CLIENT_ID}" --data-urlencode "scope=${SCOPE}")

err=$(printf '%s' "$dc" | jget error)
if [ -n "$err" ]; then
  echo "error from device/code: ${err} — $(printf '%s' "$dc" | jget error_description)" >&2
  [ "$err" = "device_flow_disabled" ] && echo "Enable 'Device Flow' on the OAuth App's settings page." >&2
  exit 1
fi

device_code=$(printf '%s' "$dc" | jget device_code)
user_code=$(printf '%s' "$dc" | jget user_code)
verification_uri=$(printf '%s' "$dc" | jget verification_uri)
interval=$(printf '%s' "$dc" | jget interval); interval=${interval:-5}

echo
echo "  ➜ Open:  ${verification_uri}"
echo "  ➜ Code:  ${user_code}"
echo
echo "Waiting for authorization..."

while true; do
  sleep "$interval"
  resp=$(curl -sS -X POST https://github.com/login/oauth/access_token \
    -H "Accept: application/json" \
    -d "client_id=${CLIENT_ID}" \
    -d "device_code=${device_code}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code")

  access_token=$(printf '%s' "$resp" | jget access_token)
  [ -n "$access_token" ] && break

  e=$(printf '%s' "$resp" | jget error)
  case "$e" in
    authorization_pending) ;;                 # keep waiting
    slow_down) interval=$((interval + 5)) ;;  # back off
    "") echo "unexpected response: ${resp}" >&2; exit 1 ;;
    *) echo "login failed: ${e} — $(printf '%s' "$resp" | jget error_description)" >&2; exit 1 ;;
  esac
done

mkdir -p "$CONFIG_DIR"
printf '%s' "$resp" | python3 -c '
import sys, json, time, os
d = json.load(sys.stdin)
now = int(time.time())
out = {
    "access_token": d["access_token"],
    "token_type": d.get("token_type", "bearer"),
    "scope": d.get("scope", ""),
}
def stamp(secs): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + int(secs)))
if "expires_in" in d:
    out["expires_at"] = stamp(d["expires_in"])
if "refresh_token" in d:
    out["refresh_token"] = d["refresh_token"]
    if "refresh_token_expires_in" in d:
        out["refresh_token_expires_at"] = stamp(d["refresh_token_expires_in"])
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(out, f, indent=2)
' "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE" 2>/dev/null || true

echo "Logged in. Token cached at ${TOKEN_FILE}"
