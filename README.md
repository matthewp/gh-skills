# gh-skills

Portable **[Agent Skills](https://agentskills.io)** that teach any agent to use the
GitHub API. The expertise lives in documentation, not in a library or a
bundled SDK — give an agent a skill plus any way to make HTTP requests (a shell
with `curl`, an HTTP tool, etc.) and it can read and write GitHub data.

Three skills, same GitHub knowledge, differing in **how the token shows up** and
**which capability the agent has**:

| Skill | Auth | Use when |
| --- | --- | --- |
| **`github-client`** | Acquires its own token: `GITHUB_TOKEN` → cached token → **OAuth device-flow login** | The agent can interact with the user (prompt a browser login) and has a shell + `jq`. |
| **`github-api`** | A token is **provided** to it (env or passed in); never logs anyone in | Headless/server contexts, or an orchestrator hands the agent a token. |
| **`github-client-pure`** | Same as `github-client` (device flow), done over plain HTTP | The agent can **only** make HTTP requests — no shell, no `jq`, no code runtime. Uses GraphQL so the server trims responses. |

```
gh-skills/
├─ github-client/                  # full client — does its own auth (shell + jq)
│  ├─ SKILL.md
│  ├─ references/
│  │  ├─ authentication.md         # token cache, OAuth device flow + refresh, scopes, errors
│  │  ├─ endpoints.md               # endpoint catalog + the useful fields to select
│  │  └─ search-syntax.md
│  └─ scripts/
│     ├─ login.sh                  # turnkey device-flow login → writes the token cache
│     └─ api.sh                    # authed request helper: resolves token, sends headers, trims via -q jq filter
├─ github-client-pure/             # pure HTTP — no shell/jq; GraphQL reads, REST writes
│  ├─ SKILL.md
│  └─ references/
│     ├─ authentication.md         # device flow over HTTP; shared token cache
│     ├─ graphql.md                # GraphQL query catalog + field vocabulary
│     └─ search-syntax.md
└─ github-api/                     # calls only — token is supplied
   ├─ SKILL.md
   └─ references/
      ├─ endpoints.md
      └─ search-syntax.md
```

Each is a self-contained Agent Skill directory (the shared `references/` are
copied into both so either can be used independently). An agent loads `SKILL.md`
first and pulls in `references/` only when a task needs them (progressive
disclosure).

## Using a skill

**Any Agent Skills-compatible runtime** — drop the skill directory where the
runtime discovers skills (commonly `<workspace>/.agents/skills/`).

**Flue** — import the one you want into an agent or workflow:

```ts
import githubClient from '../path/to/gh-skills/github-client/SKILL.md' with { type: 'skill' };
// or, for headless use with a caller-supplied token:
import githubApi from '../path/to/gh-skills/github-api/SKILL.md' with { type: 'skill' };

export default createAgent(() => ({
  model: 'anthropic/claude-sonnet-4-6',
  skills: [githubClient],
  // plus an executable capability: a sandbox (curl) or an HTTP request tool
}));
```

A skill provides knowledge only — it does not execute anything. Pair it with an
execution capability (and, for `github-api`, a token).

## Auth & safety

- **`github-client`** acquires and manages its own token: `GITHUB_TOKEN` if set →
  a **cached token** at `~/.config/gh-skills/token.json` (reused until it expires,
  refreshed when it can) → otherwise an OAuth **device-flow** login (run
  `github-client/scripts/login.sh`). It ships its own registered OAuth App, so
  login works out of the box; `GITHUB_OAUTH_CLIENT_ID` overrides it with your own.
  No PAT prompting.
- **`github-api`** never logs anyone in: it uses a token the caller supplies and
  stops if none is available.
- Both keep the token scoped to `api.github.com`, and never echo or hard-code it.
- Do not put real tokens in this directory — it is meant to be shared/committed.

## Token efficiency

[`tests/`](tests/) holds a CI-able benchmark that runs a headless agent over
read-only prompts and measures token usage per approach. A snapshot (Sonnet,
5 prompts vs `cli/cli`, cold, 1 run/cell):

| Approach | Total cost | Turns | ×gh |
| --- | --- | --- | --- |
| `gh` CLI (baseline) | $0.3030 | 10 | 1.00× |
| `github-client` (REST + `curl`) | $0.4691 | 21 | 1.55× |
| `github-client-pure` (GraphQL) | $0.5030 | 25 | 1.66× |

`gh` is the cheapest (compact, field-selected output); the skills cost more
mostly from the one-time skill load (it **amortizes** across a multi-task
session — warm, `github-client` is ~1.35× `gh`). `github-client-pure`'s GraphQL
trims responses server-side but spends more composing queries, so its value is
**portability** (no shell/`jq`), not raw token cost. See
[`tests/README.md`](tests/README.md) for the full tables, warm-vs-cold, and how
to run it.

## Related

The knowledge-as-a-skill counterpart to the `gh-agent` prototype (a Flue
agent/workflow with a typed GitHub tool). Same goal — a reusable GitHub access
layer — expressed as portable documentation instead of code.
