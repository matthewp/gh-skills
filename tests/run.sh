#!/usr/bin/env bash
# Token-efficiency benchmark: GitHub skills vs the `gh` CLI.
#
# For each prompt in prompts.json, runs a headless `claude -p` agent under each
# condition in $CONDITIONS and records token usage, cost, and the answer:
#
#   skill  — the github-client skill (REST + curl) is mounted in a temp project's
#            .claude/skills/; gh is blocked via a PATH shim; GITHUB_TOKEN set.
#   pure   — the github-client-pure skill (GraphQL, no shell/jq) is mounted; gh
#            blocked; GITHUB_TOKEN set.
#   gh     — no skill; the gh CLI is available and authenticated.
#
# Then it writes tests/results/{records.jsonl,summary.json,summary.md} and prints
# a comparison (ratios vs $BASELINE). Exit non-zero if any run errored.
#
# Prompts MUST be read-only against public repos — runs use bypassPermissions.
#
# Config (env):
#   CONDITIONS   space-separated subset of "skill pure gh" (default "skill gh")
#   BASELINE     condition to compute ratios against (default gh)
#   MODEL        model alias/id (default claude-sonnet-4-6)
#   RUNS         runs per cell, averaged (default 1)
#   TIMEOUT      per-run timeout seconds (default 240)
#   GITHUB_TOKEN token for all conditions (falls back to `gh auth token`)
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
CONDITIONS="${CONDITIONS:-skill gh}"
BASELINE="${BASELINE:-gh}"

# Per-condition skill dir ("" = no skill) and system steer.
cond_skill_dir(){ case "$1" in skill) echo github-client;; pure) echo github-client-pure;; *) echo "";; esac; }
cond_sys(){ case "$1" in
  skill) echo "You can make HTTP requests with curl and you have a Skill named 'github-client' (a GitHub REST API client). Use that skill and the REST API to answer. The gh CLI is NOT available.";;
  pure)  echo "You can make HTTP requests with curl and you have a Skill named 'github-client-pure' (a pure-HTTP GitHub client that reads via GraphQL). Use that skill to answer. The gh CLI is NOT available.";;
  gh)    echo "Use the gh CLI (the 'gh' command) to answer GitHub questions. It is installed and authenticated.";;
esac; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need claude; need jq; need curl

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || { echo "error: set GITHUB_TOKEN (or log into gh) so the benchmark can call GitHub" >&2; exit 1; }

mkdir -p "$RUNS_DIR"
RECORDS="$OUT/records.jsonl"; : > "$RECORDS"

run_one(){ # id prompt condition runidx
  local id="$1" prompt="$2" cond="$3" idx="$4"
  local work sys skilldir; work="$(mktemp -d)"; local pre=()
  sys="$(cond_sys "$cond")"; skilldir="$(cond_skill_dir "$cond")"
  if [ -n "$skilldir" ]; then
    mkdir -p "$work/.claude/skills" "$work/bin"
    ln -s "$ROOT/$skilldir" "$work/.claude/skills/$skilldir"
    printf '#!/usr/bin/env bash\necho "gh unavailable here — use the GitHub API (curl) per the %s skill" >&2\nexit 127\n' "$skilldir" > "$work/bin/gh"
    chmod +x "$work/bin/gh"
    pre=(env "PATH=$work/bin:$PATH" "GITHUB_TOKEN=$TOKEN")
  else
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
echo "Benchmarking $n prompts × {$CONDITIONS} × $RUNS run(s) on $MODEL" >&2
for ((i=0;i<n;i++)); do
  id=$(jq -r ".[$i].id" "$PROMPTS")
  prompt=$(jq -r ".[$i].prompt" "$PROMPTS")
  for cond in $CONDITIONS; do
    for ((r=1;r<=RUNS;r++)); do
      echo ">> $id [$cond] $r/$RUNS" >&2
      run_one "$id" "$prompt" "$cond" "$r" || fail=1
    done
  done
done

# Aggregate (mean per id+condition) into summary.json: {id,title,conds:{<cond>:{...}}}
jq -s --slurpfile prompts "$PROMPTS" '
  def mean(f): if length==0 then 0 else ((map(f)|add) / length) end;
  (INDEX($prompts[0][]; .id)) as $titles
  | group_by(.id)
  | map(
      .[0].id as $id
      | { id:$id, title: ($titles[$id].title // $id),
          conds: (group_by(.condition) | map({ (.[0].condition): {
              ok: all(.ok), cost_usd: mean(.cost_usd), out_tokens: mean(.out_tokens),
              total_in: mean(.total_in), num_turns: mean(.num_turns)
          }}) | add) }
    )
' "$RECORDS" > "$OUT/summary.json"

# Render markdown + stdout summary (N conditions; ratios vs $BASELINE)
render(){
  local conds_json; conds_json=$(printf '%s\n' $CONDITIONS | jq -R . | jq -sc .)
  echo "# Token-efficiency: GitHub skills vs gh CLI"
  echo
  echo "Model \`$MODEL\` · $RUNS run(s)/cell · conditions: $CONDITIONS · baseline: $BASELINE · $(date -u +%FT%TZ)"
  echo
  # Per-prompt cost table (one column per condition)
  printf "| Prompt |"; for c in $CONDITIONS; do printf " %s |" "$c"; done; echo
  printf "|---|"; for c in $CONDITIONS; do printf '%s' "---|"; done; echo
  jq -r --argjson cs "$conds_json" '.[] | [.title] + [ $cs[] as $c | (.conds[$c].cost_usd // 0) ] | @tsv' "$OUT/summary.json" |
  while IFS=$'\t' read -ra f; do
    row="| ${f[0]} |"; for ((j=1;j<${#f[@]};j++)); do row+="$(printf ' $%.4f |' "${f[j]}")"; done; echo "$row"
  done
  echo
  # Totals + ratio vs baseline, one row per condition
  echo "| Condition | Total cost | Output tok | Input tok | Turns | ×$BASELINE cost |"
  echo "|---|---|---|---|---|---|"
  local base_cost; base_cost=$(jq -r --arg c "$BASELINE" '(map(.conds[$c].cost_usd//0)|add)' "$OUT/summary.json")
  for c in $CONDITIONS; do
    read -r CC OO II TT < <(jq -r --arg c "$c" '"\(map(.conds[$c].cost_usd//0)|add)\t\(map(.conds[$c].out_tokens//0)|add)\t\(map(.conds[$c].total_in//0)|add)\t\(map(.conds[$c].num_turns//0)|add)"' "$OUT/summary.json")
    printf "| %s | \$%.4f | %.0f | %.0f | %.0f | %s |\n" "$c" "$CC" "$OO" "$II" "$TT" \
      "$(awk -v a="$CC" -v b="$base_cost" 'BEGIN{printf (b? "%.2f×":"—"), a/b}')"
  done
}
render | tee "$OUT/summary.md"

echo >&2
if [ "$fail" -ne 0 ]; then echo "FAIL: one or more runs errored (see $RUNS_DIR/*.err)" >&2; exit 1; fi
echo "OK — results in $OUT/" >&2
