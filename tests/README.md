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

## Warm vs cold skill load

`run.sh` runs each prompt as a **fresh** `claude -p` process, so it pays the
SKILL.md load every time — the **cold** worst case. In a real session you load
the skill once and reuse it. [`warmcold.sh`](warmcold.sh) isolates that variable:
for each prompt it measures the task **cold** (fresh session) and **warm** (a
primer task loads the skill, then the real task runs via `claude --resume`), and
reports `premium = cold − warm`.

```bash
GITHUB_TOKEN=$(gh auth token) tests/warmcold.sh   # -> tests/results-warmcold/
```

Measured (Sonnet, 5 prompts): cold ≈ **$0.094/task** (4–5 turns), warm ≈
**$0.028/task** (2–3 turns) — **warm is ~3.4× cheaper**, a cold load adds
**~$0.067/task**, paid once per session. Cold runs write ~10k `cache_creation`
tokens (skill + context into cache) and spend an extra ~2 turns; warm runs write
almost none. So a multi-task session amortizes the load — divide the cold premium
by the number of GitHub tasks in the session.

**Caveat:** the premium mixes the skill load with generic cold prompt-cache
warm-up (~7k system-prompt tokens that the `gh` baseline also pays cold). Don't
compare warm-skill against the (cold) `gh` column — that's apples-to-oranges. A
fair warm-vs-warm skill/gh number would require measuring `gh` warm too (not yet
done; see "next steps").

## Notes

- Token counts are non-deterministic (model variation). `RUNS=3+` averages the
  **cold** number to cut noise — it does **not** measure warm/cold (every run is
  a fresh cold start); use `warmcold.sh` for that.
- `summary.json` is machine-readable for trend tracking across commits.

### Next steps
- Add a **warm `gh`** condition so skill/gh can be compared warm-vs-warm (fair),
  not just cold-vs-cold.
- Add `github-client-pure` and `github-api` as conditions to compare all three
  skills in one table.

## CI

[`.github/workflows/token-bench.yml`](../.github/workflows/token-bench.yml) runs
this on manual dispatch (it costs API tokens, so it's not automatic). It needs an
`ANTHROPIC_API_KEY` secret; the workflow's built-in `GITHUB_TOKEN` covers the
read-only public GitHub calls. The comparison table is posted to the run's job
summary and the raw results are uploaded as an artifact.
