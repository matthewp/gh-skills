#!/usr/bin/env bash
# Token-efficiency benchmark: the `github-client` skill vs the `gh` CLI.
#
# For each prompt in prompts.json, runs a headless `claude -p` agent under two
# conditions and records token usage, cost, and the answer:
#
#   skill  — the github-client skill is available (in a temp project's
#            .claude/skills/), gh is blocked via a PATH shim so the agent must
#            use the REST API (curl); GITHUB_TOKEN is provided.
#   gh     — no skill; the gh CLI is available and authenticated.
#
# Then it writes tests/results/{records.jsonl,summary.json,summary.md} and
# prints a comparison. Exit non-zero if any run errored (good for CI).
#
# Prompts MUST be read-only against public repos — runs use bypassPermissions.
#
# Config (env):
#   MODEL        model alias/id for both conditions (default claude-sonnet-4-6)
#   RUNS         runs per cell, averaged (default 1)
#   TIMEOUT      per-run timeout seconds (default 240)
#   GITHUB_TOKEN token for both conditions (falls back to `gh auth token`)
#   OUT_DIR      output dir (default tests/results)
#   PROMPTS_FILE prompts JSON (default tests/prompts.json)
#
# Requires: claude, jq, curl, gh (for the gh condition), and Claude auth
# (ANTHROPIC_API_KEY or a logged-in CLI).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ROOT/tests"
OUT="${OUT_DIR:-$TESTS/results}"
RUNS_DIR="$OUT/runs"
MODEL="${MODEL:-claude-sonnet-4-6}"
RUNS="${RUNS:-1}"
TIMEOUT="${TIMEOUT:-240}"
PROMPTS="${PROMPTS_FILE:-$TESTS/prompts.json}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need claude; need jq; need curl

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || { echo "error: set GITHUB_TOKEN (or log into gh) so the benchmark can call GitHub" >&2; exit 1; }

mkdir -p "$RUNS_DIR"
RECORDS="$OUT/records.jsonl"; : > "$RECORDS"

run_one(){ # id prompt condition runidx
  local id="$1" prompt="$2" cond="$3" idx="$4"
  local work sys; work="$(mktemp -d)"; local pre=()
  if [ "$cond" = "skill" ]; then
    mkdir -p "$work/.claude/skills" "$work/bin"
    ln -s "$ROOT/github-client" "$work/.claude/skills/github-client"
    printf '#!/usr/bin/env bash\necho "gh unavailable here — use the GitHub REST API (curl) per the github-client skill" >&2\nexit 127\n' > "$work/bin/gh"
    chmod +x "$work/bin/gh"
    sys="You can make HTTP requests with curl and you have a Skill named 'github-client' (a GitHub REST API client). Use that skill and the REST API to answer. The gh CLI is NOT available."
    pre=(env "PATH=$work/bin:$PATH" "GITHUB_TOKEN=$TOKEN")
  else
    sys="Use the gh CLI (the 'gh' command) to answer GitHub questions. It is installed and authenticated."
    pre=(env "GH_TOKEN=$TOKEN" "GITHUB_TOKEN=$TOKEN")
  fi

  local raw="$RUNS_DIR/${id}__${cond}__${idx}.json"
  ( cd "$work" && timeout "$TIMEOUT" "${pre[@]}" claude -p "$prompt" \
      --output-format json --model "$MODEL" \
      --permission-mode bypassPermissions \
      --append-system-prompt "$sys" \
      --add-dir "$work" >"$raw" 2>"$raw.err" )
  local rc=$?
  rm -rf "$work"

  if [ $rc -ne 0 ] || ! jq -e 'has("usage")' "$raw" >/dev/null 2>&1; then
    echo "   ! failed (rc=$rc) — see $raw.err" >&2
    jq -nc --arg id "$id" --arg cond "$cond" --argjson idx "$idx" \
      '{id:$id,condition:$cond,run:$idx,ok:false}' >> "$RECORDS"
    return 1
  fi
  jq -c --arg id "$id" --arg cond "$cond" --argjson idx "$idx" '{
    id:$id, condition:$cond, run:$idx,
    ok: (.is_error|not),
    num_turns: (.num_turns//0),
    duration_ms: (.duration_ms//0),
    cost_usd: (.total_cost_usd//0),
    out_tokens: (.usage.output_tokens//0),
    total_in: ((.usage.input_tokens//0)+(.usage.cache_read_input_tokens//0)+(.usage.cache_creation_input_tokens//0)),
    result: (.result//"")
  }' "$raw" >> "$RECORDS"
}

fail=0
n=$(jq length "$PROMPTS")
echo "Benchmarking $n prompts × {skill, gh} × $RUNS run(s) on $MODEL" >&2
for ((i=0;i<n;i++)); do
  id=$(jq -r ".[$i].id" "$PROMPTS")
  prompt=$(jq -r ".[$i].prompt" "$PROMPTS")
  for cond in skill gh; do
    for ((r=1;r<=RUNS;r++)); do
      echo ">> $id [$cond] $r/$RUNS" >&2
      run_one "$id" "$prompt" "$cond" "$r" || fail=1
    done
  done
done

# Aggregate (mean per id+condition) into summary.json
jq -s --slurpfile prompts "$PROMPTS" '
  def mean(f): if length==0 then 0 else ((map(f)|add) / length) end;
  (INDEX($prompts[0][]; .id)) as $titles
  | group_by(.id)
  | map(
      .[0].id as $id
      | (group_by(.condition) | map({ (.[0].condition): {
            ok: all(.ok),
            cost_usd: mean(.cost_usd),
            out_tokens: mean(.out_tokens),
            total_in: mean(.total_in),
            num_turns: mean(.num_turns),
            duration_ms: mean(.duration_ms)
        }}) | add) as $b
      | { id:$id, title: ($titles[$id].title // $id), skill: ($b.skill//null), gh: ($b.gh//null) }
    )
' "$RECORDS" > "$OUT/summary.json"

# Render markdown + stdout summary
render(){
  echo "# Token-efficiency: github-client skill vs gh CLI"
  echo
  echo "Model \`$MODEL\` · $RUNS run(s)/cell · $(date -u +%FT%TZ)"
  echo
  echo "| Prompt | Cost (skill/gh) | Output tok (skill/gh) | Input tok (skill/gh) | Turns (s/g) |"
  echo "|---|---|---|---|---|"
  jq -r '.[] | [.title,
      (.skill.cost_usd//0),(.gh.cost_usd//0),
      (.skill.out_tokens//0),(.gh.out_tokens//0),
      (.skill.total_in//0),(.gh.total_in//0),
      (.skill.num_turns//0),(.gh.num_turns//0)] | @tsv' "$OUT/summary.json" |
  while IFS=$'\t' read -r t sc gc so go si gi st gt; do
    printf "| %s | \$%.4f / \$%.4f | %.0f / %.0f | %.0f / %.0f | %.0f / %.0f |\n" "$t" "$sc" "$gc" "$so" "$go" "$si" "$gi" "$st" "$gt"
  done
  # totals + ratios
  read -r SC GC SO GO SI GI < <(jq -r '
    [ (map(.skill.cost_usd//0)|add), (map(.gh.cost_usd//0)|add),
      (map(.skill.out_tokens//0)|add), (map(.gh.out_tokens//0)|add),
      (map(.skill.total_in//0)|add), (map(.gh.total_in//0)|add) ] | @tsv' "$OUT/summary.json")
  printf "| **Total** | \$%.4f / \$%.4f | %.0f / %.0f | %.0f / %.0f | |\n" "$SC" "$GC" "$SO" "$GO" "$SI" "$GI"
  echo
  awk -v sc="$SC" -v gc="$GC" -v so="$SO" -v go="$GO" -v si="$SI" -v gi="$GI" 'BEGIN{
    printf "**skill ÷ gh** — cost %.2f× · output %.2f× · input %.2f×\n", (gc?sc/gc:0),(go?so/go:0),(gi?si/gi:0)
  }'
}
render | tee "$OUT/summary.md"

echo >&2
if [ "$fail" -ne 0 ]; then echo "FAIL: one or more runs errored (see $RUNS_DIR/*.err)" >&2; exit 1; fi
echo "OK — results in $OUT/" >&2
