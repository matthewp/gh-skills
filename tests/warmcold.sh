#!/usr/bin/env bash
# Cold-start vs warm cost of the github-client skill.
#
# The main benchmark (run.sh) pays the skill load on every prompt — the worst
# case. In a real session you load the skill once and amortize it. This isolates
# that: for each prompt it measures the same task two ways, skill mounted both
# times, gh blocked both times:
#
#   cold — fresh session: the agent invokes the skill (reads SKILL.md) and does
#          the task. Pays the skill load + cold prompt-cache.
#   warm — a small primer task first loads the skill into a session; then the
#          real task runs via `claude --resume`. Skill already in context, cache
#          warm. We record only the resumed (warm) call.
#
# premium = cold − warm ≈ the per-task cost of a cold skill load.
#
# Output: tests/results-warmcold/{records.jsonl,summary.json,summary.md}.
# Config: MODEL, TIMEOUT, GITHUB_TOKEN, OUT_DIR, PROMPTS_FILE (same as run.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ROOT/tests"
OUT="${OUT_DIR:-$TESTS/results-warmcold}"
RUNS_DIR="$OUT/runs"
MODEL="${MODEL:-claude-sonnet-4-6}"
TIMEOUT="${TIMEOUT:-240}"
PROMPTS="${PROMPTS_FILE:-$TESTS/prompts.json}"
SYS="You can make HTTP requests with curl and you have a Skill named 'github-client' (a GitHub REST API client). Use that skill and the REST API to answer. The gh CLI is NOT available."
PRIMER="Using the github-client skill, what is the login of the currently authenticated GitHub user? Answer in one word."

need(){ command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need claude; need jq; need curl

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || { echo "error: set GITHUB_TOKEN (or log into gh)" >&2; exit 1; }

mkdir -p "$RUNS_DIR"
RECORDS="$OUT/records.jsonl"; : > "$RECORDS"

mk_env(){ # -> prints a fresh workdir with the skill mounted and gh shimmed
  local work; work="$(mktemp -d)"
  mkdir -p "$work/.claude/skills" "$work/bin"
  ln -s "$ROOT/github-client" "$work/.claude/skills/github-client"
  printf '#!/usr/bin/env bash\necho "gh unavailable — use the REST API per the github-client skill" >&2\nexit 127\n' > "$work/bin/gh"
  chmod +x "$work/bin/gh"
  printf '%s' "$work"
}

skill_call(){ # work prompt [resume_sid] -> raw json on stdout
  local work="$1" prompt="$2" sid="${3:-}" extra=()
  [ -n "$sid" ] && extra=(--resume "$sid")
  ( cd "$work" && timeout "$TIMEOUT" env "PATH=$work/bin:$PATH" "GITHUB_TOKEN=$TOKEN" \
      claude -p "$prompt" "${extra[@]}" --output-format json --model "$MODEL" \
        --permission-mode bypassPermissions --append-system-prompt "$SYS" --add-dir "$work" 2>/dev/null )
}

record(){ # id phase rawjson
  local id="$1" phase="$2" raw="$3"
  if ! jq -e 'has("usage")' "$raw" >/dev/null 2>&1; then
    echo "   ! $id/$phase failed" >&2
    jq -nc --arg id "$id" --arg p "$phase" '{id:$id,phase:$p,ok:false}' >> "$RECORDS"; return 1
  fi
  jq -c --arg id "$id" --arg p "$phase" '{
    id:$id, phase:$p, ok:(.is_error|not),
    num_turns:(.num_turns//0), cost_usd:(.total_cost_usd//0),
    out_tokens:(.usage.output_tokens//0),
    total_in:((.usage.input_tokens//0)+(.usage.cache_read_input_tokens//0)+(.usage.cache_creation_input_tokens//0)),
    cache_creation:(.usage.cache_creation_input_tokens//0)
  }' "$raw" >> "$RECORDS"
}

fail=0
n=$(jq length "$PROMPTS")
echo "Warm/cold over $n prompts on $MODEL" >&2
for ((i=0;i<n;i++)); do
  id=$(jq -r ".[$i].id" "$PROMPTS"); prompt=$(jq -r ".[$i].prompt" "$PROMPTS")

  echo ">> $id [cold]" >&2
  w=$(mk_env); skill_call "$w" "$prompt" > "$RUNS_DIR/${id}__cold.json"; rm -rf "$w"
  record "$id" cold "$RUNS_DIR/${id}__cold.json" || fail=1

  echo ">> $id [warm: primer + resume]" >&2
  w=$(mk_env)
  skill_call "$w" "$PRIMER" > "$RUNS_DIR/${id}__primer.json"
  sid=$(jq -r '.session_id // empty' "$RUNS_DIR/${id}__primer.json")
  if [ -z "$sid" ]; then echo "   ! $id primer produced no session_id" >&2; rm -rf "$w"; fail=1; continue; fi
  record "$id" primer "$RUNS_DIR/${id}__primer.json" || true
  skill_call "$w" "$prompt" "$sid" > "$RUNS_DIR/${id}__warm.json"; rm -rf "$w"
  record "$id" warm "$RUNS_DIR/${id}__warm.json" || fail=1
done

jq -s --slurpfile prompts "$PROMPTS" '
  (INDEX($prompts[0][]; .id)) as $t
  | group_by(.id) | map(
      .[0].id as $id | (INDEX(.[]; .phase)) as $p
      | { id:$id, title:($t[$id].title // $id),
          cold:($p.cold//null), warm:($p.warm//null), primer:($p.primer//null),
          premium_usd:(((($p.cold.cost_usd)//0) - (($p.warm.cost_usd)//0))) }
    )
' "$RECORDS" > "$OUT/summary.json"

render(){
  echo "# Cold start vs warm: github-client skill"
  echo
  echo "Model \`$MODEL\` · $(date -u +%FT%TZ) · premium = cold − warm (per-task cost of a cold skill load)"
  echo
  echo "| Prompt | Cold \$ | Warm \$ | Premium \$ | Cold turns | Warm turns |"
  echo "|---|---|---|---|---|---|"
  jq -r '.[] | [.title,(.cold.cost_usd//0),(.warm.cost_usd//0),(.premium_usd//0),(.cold.num_turns//0),(.warm.num_turns//0)] | @tsv' "$OUT/summary.json" |
  while IFS=$'\t' read -r t cc wc pr ct wt; do
    printf "| %s | \$%.4f | \$%.4f | \$%.4f | %.0f | %.0f |\n" "$t" "$cc" "$wc" "$pr" "$ct" "$wt"
  done
  read -r CC WC < <(jq -r '[ (map(.cold.cost_usd//0)|add), (map(.warm.cost_usd//0)|add) ] | @tsv' "$OUT/summary.json")
  printf "| **Total** | \$%.4f | \$%.4f | \$%.4f | | |\n" "$CC" "$WC" "$(awk -v a="$CC" -v b="$WC" 'BEGIN{print a-b}')"
  echo
  awk -v cc="$CC" -v wc="$WC" 'BEGIN{ printf "**Warm is %.2f× cheaper than cold**; a cold skill load adds ~\$%.4f/task here, paid once per session.\n", (wc?cc/wc:0), (cc-wc)/5 }'
}
render | tee "$OUT/summary.md"

echo >&2
[ "$fail" -ne 0 ] && { echo "FAIL: some runs errored" >&2; exit 1; }
echo "OK — $OUT/" >&2
