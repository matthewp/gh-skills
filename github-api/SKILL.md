---
name: github-api
description: GitHub REST API calls with a token you are given. Uses a token supplied by the caller (GITHUB_TOKEN, or passed in by an orchestrator/workflow) to read or write issues, pull requests, repos, commits, file contents, Actions runs, and notifications, and to search — picking the right endpoint, paginating, and reading results. It does NOT log anyone in or obtain credentials: if no token is available it stops and says so. Use in headless/server contexts or when a token is provided; for interactive OAuth login use the `github-client` skill instead.
license: MIT
metadata:
  api-version: "2022-11-28"
  base-url: "https://api.github.com"
---

# GitHub REST API

Use this skill to read and write GitHub data through the REST API at
`https://api.github.com`. You issue the HTTP requests yourself with whatever
capability you have — a shell (`curl`), an HTTP request tool, or a language
runtime. This skill tells you *which* request to make and how to read the result.

## Using your token

This skill makes calls with a token **provided to you** — it does not log anyone
in or obtain credentials itself.

- Use the token from `GITHUB_TOKEN`, or one handed to you by the caller
  (orchestrator, workflow, or environment).
- Send it as `Authorization: Bearer <token>` on every request, together with
  `Accept: application/vnd.github+json` and `X-GitHub-Api-Version: 2022-11-28`.
- **If no token is available, stop and say so** — you cannot acquire one here.
  (The `github-client` skill handles interactive OAuth login; this skill is for
  headless use where a token is supplied.)
- Only ever send the token to `api.github.com` — never put it in a URL, send it
  to another host, echo it, or write it to a shared/committed file.

**When is a token required?** Public, read-only data works without one but is
capped at 60 requests/hour (authenticated: 5,000/hour), and private resources are
invisible (they return `404`). Anything private, any write, and `search/code`
require a token.

## The request shape

Every call is `METHOD https://api.github.com<path>` with the three headers
above. Paths use `{owner}/{repo}` and resource ids, e.g.
`/repos/{owner}/{repo}/issues/{number}`. Bodies (for POST/PATCH) are JSON; add
`-H "Content-Type: application/json" -d '{...}'`.

## Most-used recipes

**5 most recent open issues in a repo** (newest first; note: this endpoint also
returns pull requests — skip any item that has a `pull_request` field):

```bash
curl -sS "https://api.github.com/repos/vercel/next.js/issues?state=open&sort=created&direction=desc&per_page=5" \
  -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json"
```

**Search issues/PRs across GitHub** (returns `{ total_count, items }`):

```bash
curl -sS "https://api.github.com/search/issues?q=repo:facebook/react+is:issue+is:open+label:bug&sort=created&order=desc&per_page=5" \
  -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json"
```

**One issue with its body:** `GET /repos/{owner}/{repo}/issues/{number}`
**Recent commits on a branch:** `GET /repos/{owner}/{repo}/commits?sha={branch}&per_page=10`
**A file's contents:** `GET /repos/{owner}/{repo}/contents/{path}?ref={branch}` (content is base64; or send `Accept: application/vnd.github.raw` for the raw bytes).

See `references/endpoints.md` for the full catalog and `references/search-syntax.md` for search qualifiers.

## Conventions that trip people up

- **"Most recent" / "latest"** → `sort=created&direction=desc`. **"Top N"** → `per_page=N`.
- The repo **issues** list includes PRs. Filter them out by checking for a `pull_request` key on each item.
- **Pagination:** `per_page` (max 100) + `page`. The response `Link` header carries `rel="next"`; follow it to page, stop when it's absent.
- **Dates** are ISO 8601 UTC (`2026-06-19T20:13:00Z`). Search supports ranges like `created:>=2026-01-01`.
- **Search has its own, lower rate limit** (~30 requests/min) and caps results at 1,000 — narrow the query rather than paging deeply.
- Prefer the **smallest** request: a specific path + `per_page` over fetching everything and filtering client-side.

## Errors & rate limits

- `401` invalid/expired token — the supplied token is bad or expired; request a fresh one from whoever provided it. `403` often a rate-limit or permission issue · `404` missing **or** no access (GitHub hides private resources as 404) · `422` validation error (bad query/params).
- Check `X-RateLimit-Remaining` and `X-RateLimit-Reset` (epoch seconds). On `403`/`429` with a `Retry-After` header, wait that many seconds before retrying. Back off on secondary-rate-limit messages.
- On error, the JSON body has a `message` and often a `documentation_url` — read it before retrying.
