# Token-efficiency benchmark

Measures how many tokens (and dollars) an agent spends doing the same GitHub
tasks two ways, so we can track the `github-client` skill against the `gh` CLI
baseline as the skill changes.

## What it does

For each prompt in [`prompts.json`](prompts.json), [`run.sh`](run.sh) runs a
headless `claude -p` agent under two conditions and records its reported token
usage:

| Condition | Setup | Method the agent must use |
| --- | --- | --- |
| `skill` | `github-client` skill mounted in a temp project's `.claude/skills/`; `gh` shadowed by a PATH shim that fails; `GITHUB_TOKEN` provided | the GitHub REST API via `curl`, guided by the skill |
| `gh` | no skill; `gh` installed + authenticated | the `gh` CLI |

Both conditions get the **same prompt and model**. The difference in token usage
is the cost of the approach: skill-loading + REST/JSON verbosity vs `gh`'s
compact, field-selected output.

Output (in `results/`, git-ignored):
- `runs/<id>__<cond>__<n>.json` — the full `claude` result for each run
- `records.jsonl` — one parsed record per run
- `summary.json` / `summary.md` — the per-prompt comparison and totals

The script **exits non-zero if any run errored**, so CI catches a broken skill.

## Sample results

A snapshot (model `claude-sonnet-4-6`, 1 run/cell, 5 prompts vs `cli/cli`).
Numbers are illustrative — re-run to refresh; treat small deltas as noise.

| Prompt | Cost (skill / gh) | Output tok (skill / gh) | Input tok (skill / gh) | Turns (s/g) |
|---|---|---|---|---|
| One issue's title and author | $0.0878 / $0.0591 | 278 / 173 | 77,523 / 48,120 | 4 / 2 |
| 5 most recent commits | $0.0949 / $0.0629 | 608 / 351 | 77,894 / 48,301 | 4 / 2 |
| 5 most recent open issues | $0.1075 / $0.0611 | 764 / 271 | 105,732 / 48,201 | 5 / 2 |
| Repo summary stats | $0.0897 / $0.0588 | 378 / 158 | 77,578 / 48,104 | 4 / 2 |
| Search open bug issues | $0.0923 / $0.0604 | 500 / 239 | 77,717 / 48,168 | 4 / 2 |
| **Total** | **$0.4723 / $0.3024** | **2,528 / 1,192** | **416,444 / 240,894** | |

**skill ÷ gh — cost 1.56× · output 2.12× · input 1.73×** (cold-vs-cold). `gh` is a
flat 2 turns; the skill takes 4–5 (invoke skill → `curl` → answer). Part of this
gap is the one-time skill load, which amortizes in a warm session — but a smaller
gap persists even warm. See warm vs cold below.

## Running locally

```bash
# needs: claude (logged in or ANTHROPIC_API_KEY), jq, curl, gh
GITHUB_TOKEN=$(gh auth token) tests/run.sh
```

Config via env: `MODEL` (default `claude-sonnet-4-6`), `RUNS` (per-cell, averaged;
default 1), `TIMEOUT` (per-run seconds, default 240), `PROMPTS_FILE`, `OUT_DIR`.

```bash
# cheaper smoke run: one prompt on Haiku
MODEL=claude-haiku-4-5-20251001 PROMPTS_FILE=<(jq '[.[0]]' tests/prompts.json) tests/run.sh
```

Prompts **must be read-only against public repos** — runs use
`--permission-mode bypassPermissions`.

## Warm vs cold — skill *and* gh

`run.sh` runs each prompt as a **fresh** `claude -p` process, so it pays a cold
start every time — the worst case. In a real session you reuse a warm context.
[`warmcold.sh`](warmcold.sh) measures both conditions cold and warm: for each
prompt × {skill, gh} it runs the task **cold** (fresh session) and **warm** (a
primer task warms the session — loading the skill for `skill`, warming the prompt
cache for both — then the real task runs via `claude --resume`).

```bash
GITHUB_TOKEN=$(gh auth token) tests/warmcold.sh   # -> tests/results-warmcold/
```

Measured (model `claude-sonnet-4-6`, 5 prompts, cost per task):

| Prompt | Skill cold | Skill warm | gh cold | gh warm |
|---|---|---|---|---|
| One issue's title and author | $0.0881 | $0.0219 | $0.0597 | $0.0194 |
| 5 most recent commits | $0.0925 | $0.0260 | $0.0626 | $0.0218 |
| 5 most recent open issues | $0.1086 | $0.0415 | $0.0611 | $0.0211 |
| Repo summary stats | $0.0886 | $0.0235 | $0.0588 | $0.0187 |
| Search open bug issues | $0.0920 | $0.0235 | $0.0611 | $0.0197 |
| **Total** | **$0.4699** | **$0.1364** | **$0.3033** | **$0.1007** |

**skill ÷ gh — cold 1.55× · warm 1.35×.** Both warm by ~3× (skill 3.45×, gh
3.01×), so warming is the bigger lever for *either* approach than the choice
between them.

The skill/gh gap **narrows** warm but doesn't close. Decomposing the per-task
difference: cold skill−gh ≈ **$0.033/task**, warm skill−gh ≈ **$0.007/task**. So
~$0.026 is the **cold skill load** (amortizes once per session) and ~$0.007 is a
**persistent** cost that survives warming — the REST/JSON path being more verbose
and a turn or two longer than `gh`'s compact output. Earlier framing ("skill load
is most of the cost") was wrong: `gh` pays a nearly identical cold-cache premium.

## Notes

- Token counts are non-deterministic (model variation). `RUNS=3+` averages the
  **cold** number to cut noise — it does **not** measure warm/cold (every run is
  a fresh cold start); use `warmcold.sh` for that.
- `summary.json` is machine-readable for trend tracking across commits.

### Next steps
- Add `github-client-pure` and `github-api` as conditions to compare all three
  skills in one table.

## CI

[`.github/workflows/token-bench.yml`](../.github/workflows/token-bench.yml) runs
this on manual dispatch (it costs API tokens, so it's not automatic). It needs an
`ANTHROPIC_API_KEY` secret; the workflow's built-in `GITHUB_TOKEN` covers the
read-only public GitHub calls. The comparison table is posted to the run's job
summary and the raw results are uploaded as an artifact.
