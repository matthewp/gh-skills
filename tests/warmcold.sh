#!/usr/bin/env bash
# Cold-start vs warm cost, for BOTH the github-client skill and the gh CLI.
#
# run.sh runs every prompt as a fresh process (cold worst case). This isolates
# the cold-start premium and lets skill vs gh be compared warm-vs-warm (fair) as
# well as cold-vs-cold. For each prompt × condition it measures:
#
#   cold — fresh session: the agent loads what it needs and does the task.
#   warm — a small primer task warms the session (loads the skill for `skill`,
#          warms the prompt cache for both); the real task then runs via
#          `claude --resume`. We record only the resumed (warm) call.
#
# Conditions:
#   skill — github-client mounted in a temp .claude/skills/; gh blocked by a PATH
#           shim so the agent must use the REST API (curl); GITHUB_TOKEN set.
#   gh    — no skill; gh installed + authenticated.
#
# Output: tests/results-warmcold/{records.jsonl,summary.json,summary.md}.
# Config: MODEL, TIMEOUT, GITHUB_TOKEN, OUT_DIR, PROMPTS_FILE, CONDITIONS
#         (default "skill gh").
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ROOT/tests"
OUT="${OUT_DIR:-$TESTS/results-warmcold}"
RUNS_DIR="$OUT/runs"
MODEL="${MODEL:-claude-sonnet-4-6}"
TIMEOUT="${TIMEOUT:-240}"
PROMPTS="${PROMPTS_FILE:-$TESTS/prompts.json}"
CONDITIONS="${CONDITIONS:-skill gh}"

SYS_skill="You can make HTTP requests with curl and you have a Skill named 'github-client' (a GitHub REST API client). Use that skill and the REST API to answer. The gh CLI is NOT available."
SYS_gh="Use the gh CLI (the 'gh' command) to answer GitHub questions. It is installed and authenticated."
PRIMER_skill="Using the github-client skill, what is the login of the currently authenticated GitHub user? Answer in one word."
PRIMER_gh="Using the gh CLI, what is the login of the currently authenticated GitHub user? Answer in one word."

need(){ command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need claude; need jq; need curl

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || { echo "error: set GITHUB_TOKEN (or log into gh)" >&2; exit 1; }

mkdir -p "$RUNS_DIR"
RECORDS="$OUT/records.jsonl"; : > "$RECORDS"

mk_env(){ # cond -> prints a fresh workdir
  local cond="$1" work; work="$(mktemp -d)"
  if [ "$cond" = "skill" ]; then
    mkdir -p "$work/.claude/skills" "$work/bin"
    ln -s "$ROOT/github-client" "$work/.claude/skills/github-client"
    printf '#!/usr/bin/env bash\necho "gh unavailable — use the REST API per the github-client skill" >&2\nexit 127\n' > "$work/bin/gh"
    chmod +x "$work/bin/gh"
  fi
  printf '%s' "$work"
}

call(){ # cond work prompt [resume_sid] -> raw json
  local cond="$1" work="$2" prompt="$3" sid="${4:-}" extra=() envv=() sys
  [ -n "$sid" ] && extra=(--resume "$sid")
  if [ "$cond" = "skill" ]; then sys="$SYS_skill"; envv=(env "PATH=$work/bin:$PATH" "GITHUB_TOKEN=$TOKEN")
  else sys="$SYS_gh"; envv=(env "GH_TOKEN=$TOKEN" "GITHUB_TOKEN=$TOKEN"); fi
  ( cd "$work" && timeout "$TIMEOUT" "${envv[@]}" claude -p "$prompt" "${extra[@]}" \
      --output-format json --model "$MODEL" --permission-mode bypassPermissions \
      --append-system-prompt "$sys" --add-dir "$work" 2>/dev/null )
}

record(){ # id cond phase rawfile
  local id="$1" cond="$2" phase="$3" raw="$4"
  if ! jq -e 'has("usage")' "$raw" >/dev/null 2>&1; then
    echo "   ! $id/$cond/$phase failed" >&2
    jq -nc --arg id "$id" --arg c "$cond" --arg p "$phase" '{id:$id,condition:$c,phase:$p,ok:false}' >> "$RECORDS"; return 1
  fi
  jq -c --arg id "$id" --arg c "$cond" --arg p "$phase" '{
    id:$id, condition:$c, phase:$p, ok:(.is_error|not),
    num_turns:(.num_turns//0), cost_usd:(.total_cost_usd//0),
    out_tokens:(.usage.output_tokens//0),
    total_in:((.usage.input_tokens//0)+(.usage.cache_read_input_tokens//0)+(.usage.cache_creation_input_tokens//0))
  }' "$raw" >> "$RECORDS"
}

fail=0
n=$(jq length "$PROMPTS")
echo "Warm/cold × {$CONDITIONS} over $n prompts on $MODEL" >&2
for ((i=0;i<n;i++)); do
  id=$(jq -r ".[$i].id" "$PROMPTS"); prompt=$(jq -r ".[$i].prompt" "$PROMPTS")
  for cond in $CONDITIONS; do
    primer_var="PRIMER_$cond"; primer="${!primer_var}"

    echo ">> $id [$cond cold]" >&2
    w=$(mk_env "$cond"); call "$cond" "$w" "$prompt" > "$RUNS_DIR/${id}__${cond}__cold.json"; rm -rf "$w"
    record "$id" "$cond" cold "$RUNS_DIR/${id}__${cond}__cold.json" || fail=1

    echo ">> $id [$cond warm: primer + resume]" >&2
    w=$(mk_env "$cond")
    call "$cond" "$w" "$primer" > "$RUNS_DIR/${id}__${cond}__primer.json"
    sid=$(jq -r '.session_id // empty' "$RUNS_DIR/${id}__${cond}__primer.json")
    if [ -z "$sid" ]; then echo "   ! $id/$cond primer: no session_id" >&2; rm -rf "$w"; fail=1; continue; fi
    record "$id" "$cond" primer "$RUNS_DIR/${id}__${cond}__primer.json" || true
    call "$cond" "$w" "$prompt" "$sid" > "$RUNS_DIR/${id}__${cond}__warm.json"; rm -rf "$w"
    record "$id" "$cond" warm "$RUNS_DIR/${id}__${cond}__warm.json" || fail=1
  done
done

jq -s --slurpfile prompts "$PROMPTS" '
  (INDEX($prompts[0][]; .id)) as $t
  | group_by(.id) | map(
      .[0].id as $id | (INDEX(.[]; .condition+"_"+.phase)) as $p
      | { id:$id, title:($t[$id].title // $id),
          skill_cold:($p.skill_cold//null), skill_warm:($p.skill_warm//null),
          gh_cold:($p.gh_cold//null), gh_warm:($p.gh_warm//null) }
    )
' "$RECORDS" > "$OUT/summary.json"

render(){
  echo "# Cold vs warm: github-client skill vs gh CLI"
  echo
  echo "Model \`$MODEL\` · $(date -u +%FT%TZ) · cost per task (USD)"
  echo
  echo "| Prompt | Skill cold | Skill warm | gh cold | gh warm |"
  echo "|---|---|---|---|---|"
  jq -r '.[] | [.title,(.skill_cold.cost_usd//0),(.skill_warm.cost_usd//0),(.gh_cold.cost_usd//0),(.gh_warm.cost_usd//0)] | @tsv' "$OUT/summary.json" |
  while IFS=$'\t' read -r t sc sw gc gw; do
    printf "| %s | \$%.4f | \$%.4f | \$%.4f | \$%.4f |\n" "$t" "$sc" "$sw" "$gc" "$gw"
  done
  read -r SC SW GC GW < <(jq -r '[ (map(.skill_cold.cost_usd//0)|add),(map(.skill_warm.cost_usd//0)|add),(map(.gh_cold.cost_usd//0)|add),(map(.gh_warm.cost_usd//0)|add) ] | @tsv' "$OUT/summary.json")
  printf "| **Total** | \$%.4f | \$%.4f | \$%.4f | \$%.4f |\n" "$SC" "$SW" "$GC" "$GW"
  echo
  awk -v sc="$SC" -v sw="$SW" -v gc="$GC" -v gw="$GW" 'BEGIN{
    printf "**skill ÷ gh — cold %.2f× · warm %.2f×.** Skill warm/cold %.2f×; gh warm/cold %.2f×.\n", (gc?sc/gc:0),(gw?sw/gw:0),(sw?sc/sw:0),(gw?gc/gw:0)
  }'
}
render | tee "$OUT/summary.md"

echo >&2
[ "$fail" -ne 0 ] && { echo "FAIL: some runs errored" >&2; exit 1; }
echo "OK — $OUT/" >&2
