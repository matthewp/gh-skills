---
name: github-client
description: A full GitHub REST API client that manages its own auth. Gets a token from GITHUB_TOKEN, a cached token (with its expiry), or by logging the user in via the OAuth device flow — then reads or writes issues, pull requests, repos, commits, file contents, Actions runs, and notifications, and searches. Use when an agent needs live GitHub data (api.github.com) AND may need to authenticate the user. If a token is already supplied and you cannot log anyone in (headless/server context), use the `github-api` skill instead.
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

## Authentication

This skill is a full client: it acquires and manages its own credentials. Get a
token in this order, and never invent one:

1. **Environment.** If `GITHUB_TOKEN` is set, use it (caller-provided — don't
   cache or overwrite it).
2. **Cached token.** Otherwise read the token cache at
   `${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills/token.json`. If it holds an access
   token that is not expired, use it. If it's expired but has a `refresh_token`,
   refresh it, save the result, and use it.
3. **OAuth device flow.** If there's still no usable token, log in via the OAuth
   device flow — this client does **not** ask for a Personal Access Token and does
   **not** shell out to other tools. Run `scripts/login.sh` (it requests the code,
   shows the URL + code, polls, and writes the cache), or do it by hand per
   `references/authentication.md`. The skill ships a default OAuth client id, so
   no setup is needed. On success the token and its expiry are saved to the cache
   (step 2's path); then use it.
4. **Validate** a freshly obtained token with `GET /user` (expects `200`):

   ```bash
   curl -sS https://api.github.com/user \
     -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     -H "X-GitHub-Api-Version: 2022-11-28"
   ```

5. **On `401`** (expired or revoked): delete the cached token and re-authenticate
   — refresh if possible, otherwise run the device flow again.

Always also send `Accept: application/vnd.github+json` and
`X-GitHub-Api-Version: 2022-11-28`. Only ever send the token to `api.github.com`
— never put it in a URL, send it to another host, echo it, or write it to a
shared/committed file.

**When is a token required?** Public, read-only data works without one but is
capped at 60 requests/hour (authenticated: 5,000/hour), and private resources
are invisible (they return `404`). Anything private, any write, and `search/code`
require a token — so for real work, authenticate first.

For token types, scopes per task, creating a token, and the OAuth device-flow
login, see `references/authentication.md`.

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

- `401` invalid/expired token · `403` often a rate-limit or permission issue · `404` missing **or** no access (GitHub hides private resources as 404) · `422` validation error (bad query/params).
- Check `X-RateLimit-Remaining` and `X-RateLimit-Reset` (epoch seconds). On `403`/`429` with a `Retry-After` header, wait that many seconds before retrying. Back off on secondary-rate-limit messages.
- On error, the JSON body has a `message` and often a `documentation_url` — read it before retrying.
