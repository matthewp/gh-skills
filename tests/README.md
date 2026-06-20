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

## Notes

- Token counts are non-deterministic (model variation). Use `RUNS=3+` to average
  for a stabler comparison; treat small deltas as noise.
- `summary.json` is machine-readable for trend tracking across commits.
- Only `github-client` is benchmarked for now; `github-client-pure` and
  `github-api` can be added as conditions later.

## CI

[`.github/workflows/token-bench.yml`](../.github/workflows/token-bench.yml) runs
this on manual dispatch (it costs API tokens, so it's not automatic). It needs an
`ANTHROPIC_API_KEY` secret; the workflow's built-in `GITHUB_TOKEN` covers the
read-only public GitHub calls. The comparison table is posted to the run's job
summary and the raw results are uploaded as an artifact.
