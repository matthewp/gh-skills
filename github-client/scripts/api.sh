#!/usr/bin/env bash
# gh-skills — authenticated GitHub REST API request helper.
#
# Resolves a token (GITHUB_TOKEN env → cached token.json, refreshing it if
# expired), sends the three required headers, and prints the response — optionally
# trimmed through a jq filter so you read only the fields you asked for. This is
# the token-efficient way to call the API: a bare list endpoint returns ~30 fields
# per item, so always pass `-q` with the handful you need.
#
# Usage:
#   scripts/api.sh <path> [options]
#
#   <path>        API path, with or without a leading slash or host, e.g.
#                 repos/cli/cli/issues?state=open&per_page=5
#
# Options:
#   -X METHOD     HTTP method (default GET)
#   -d JSON       request body (JSON); implies Content-Type: application/json
#   -q JQFILTER   jq filter to trim the response, e.g. '[.[]|{number,title,state}]'
#   --raw         fetch raw file bytes (Accept: application/vnd.github.raw)
#   -h            show this help
#
# Examples:
#   scripts/api.sh repos/cli/cli/issues?per_page=5 -q '[.[]|{number,title,state}]'
#   scripts/api.sh repos/o/r/issues -X POST -d '{"title":"Bug"}' -q '{number,html_url}'
#   scripts/api.sh repos/o/r/contents/README.md --raw
#
# Requires: curl, python3. jq is optional (only used for -q).
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills"
TOKEN_FILE="$CONFIG_DIR/token.json"
CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-Ov23liz5y2IEXIhpeOJk}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need curl; need python3

# Extract one top-level field from JSON on stdin (empty string if absent).
jget() {
  python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
print("" if v is None else v)
' "$1"
}

# Refresh an expired access token, save the new cache, and echo the new token.
refresh_token() {
  local rt="$1" resp at
  resp=$(curl -sS -X POST https://github.com/login/oauth/access_token \
    -H "Accept: application/json" \
    -d "client_id=${CLIENT_ID}" \
    -d "grant_type=refresh_token" --data-urlencode "refresh_token=${rt}")
  at=$(printf '%s' "$resp" | jget access_token)
  if [ -z "$at" ]; then
    echo "error: token refresh failed: $(printf '%s' "$resp" | jget error_description) — run scripts/login.sh" >&2
    return 1
  fi
  printf '%s' "$resp" | python3 -c '
import sys, json, time, os
d = json.load(sys.stdin)
now = int(time.time())
out = {"access_token": d["access_token"], "token_type": d.get("token_type","bearer"), "scope": d.get("scope","")}
def stamp(s): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now+int(s)))
if "expires_in" in d: out["expires_at"] = stamp(d["expires_in"])
if "refresh_token" in d:
    out["refresh_token"] = d["refresh_token"]
    if "refresh_token_expires_in" in d: out["refresh_token_expires_at"] = stamp(d["refresh_token_expires_in"])
fd = os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: json.dump(out, f, indent=2)
' "$TOKEN_FILE"
  printf '%s' "$at"
}

# Echo a usable bearer token: env first, then the cache (refreshing if expired).
resolve_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return 0; fi
  [ -f "$TOKEN_FILE" ] || { echo "error: no GITHUB_TOKEN and no cached token at $TOKEN_FILE — run scripts/login.sh" >&2; return 1; }
  local decision kind rest
  decision=$(python3 - "$TOKEN_FILE" <<'PY'
import sys, json, time, calendar
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("NONE"); sys.exit()
tok = d.get("access_token")
if not tok:
    print("NONE"); sys.exit()
exp = d.get("expires_at")
expired = False
if exp:
    try:
        t = calendar.timegm(time.strptime(exp, "%Y-%m-%dT%H:%M:%SZ"))
        expired = time.time() >= t - 60
    except Exception:
        expired = False
if not expired:
    print("OK\t" + tok)
elif d.get("refresh_token"):
    print("REFRESH\t" + d["refresh_token"])
else:
    print("EXPIRED")
PY
)
  kind=${decision%%$'\t'*}
  rest=${decision#*$'\t'}
  case "$kind" in
    OK)      printf '%s' "$rest"; return 0 ;;
    REFRESH) refresh_token "$rest"; return $? ;;
    EXPIRED) echo "error: cached token expired and has no refresh_token — run scripts/login.sh" >&2; return 1 ;;
    *)       echo "error: no usable token in $TOKEN_FILE — run scripts/login.sh" >&2; return 1 ;;
  esac
}

METHOD=GET; DATA=; JQF=; RAW=0; PATHARG=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    -d) DATA="$2"; shift 2 ;;
    -q) JQF="$2"; shift 2 ;;
    --raw) RAW=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) if [ -z "$PATHARG" ]; then PATHARG="$1"; shift; else echo "unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done
[ -n "$PATHARG" ] || { echo "usage: api.sh <path> [-X METHOD] [-d JSON] [-q JQFILTER] [--raw]" >&2; exit 2; }

PATHARG=${PATHARG#https://api.github.com}
PATHARG=${PATHARG#/}
URL="https://api.github.com/${PATHARG}"

TOKEN=$(resolve_token) || exit 1
ACCEPT="application/vnd.github+json"; [ "$RAW" = 1 ] && ACCEPT="application/vnd.github.raw"

curl_args=(-sS -X "$METHOD" "$URL"
  -H "Authorization: Bearer $TOKEN"
  -H "Accept: $ACCEPT"
  -H "X-GitHub-Api-Version: 2022-11-28")
[ -n "$DATA" ] && curl_args+=(-H "Content-Type: application/json" -d "$DATA")

body_file=$(mktemp); trap 'rm -f "$body_file"' EXIT
status=$(curl "${curl_args[@]}" -o "$body_file" -w '%{http_code}') || { echo "error: request to $URL failed" >&2; exit 1; }

if [ "${status:0:1}" != "2" ]; then
  echo "error: HTTP $status from $METHOD /$PATHARG" >&2
  cat "$body_file" >&2; echo >&2
  exit 1
fi

if [ "$RAW" = 1 ] || [ -z "$JQF" ]; then
  cat "$body_file"
elif command -v jq >/dev/null 2>&1; then
  jq "$JQF" < "$body_file"
else
  echo "warning: jq not installed; emitting full response (filter '$JQF' skipped)" >&2
  cat "$body_file"
fi
