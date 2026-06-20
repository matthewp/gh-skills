---
name: github-client-pure
description: A GitHub client for environments with only an HTTP request capability — no shell, no jq, no code runtime to post-process responses. Manages its own auth via the OAuth device flow (plain HTTP) and reads GitHub data with GraphQL, so the server returns only the fields you ask for — small responses, no client-side filtering needed; writes go through small REST calls. Use when an agent must talk to GitHub (api.github.com) but can only issue HTTP requests and cannot run scripts or pipe output through jq. If you have a shell and jq available, prefer the `github-client` skill.
license: MIT
metadata:
  graphql-endpoint: "https://api.github.com/graphql"
  rest-base-url: "https://api.github.com"
---

# GitHub (pure HTTP client)

Use this skill when the **only** capability you have is making HTTP requests —
no shell, no `jq`, no language runtime to trim a response after the fact. It
relies on one idea: **let the server return only the fields you need.**

The REST API has no field selection, so a single list call returns ~30 fields
per item — tens of thousands of tokens you'd then have to filter, which you
can't do here. **GraphQL selects fields server-side**, so the response arrives
already minimal. This skill therefore:

- **reads and searches with GraphQL** (`POST https://api.github.com/graphql`), and
- **writes with small REST calls** (POST/PATCH/PUT), whose responses are a single
  object you can read directly.

If you *do* have a shell and `jq` (or any code runtime), the `github-client`
skill is simpler — it trims REST responses with `jq`. This skill exists for the
transform-free case.

## Authentication

Acquire a token in this order; never invent one. (Details, scopes, and the
device-flow request/response fields are in `references/authentication.md`.)

1. **Environment.** If `GITHUB_TOKEN` is set, use it as-is — don't cache or
   overwrite it.
2. **Cached token.** Otherwise read `${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills/token.json`
   (shared with the `github-client` skill). If its `access_token` isn't expired,
   use it; if expired with a `refresh_token`, refresh and save.
3. **OAuth device flow — over HTTP.** With no usable token, log the user in by
   calling GitHub's device-flow endpoints directly (no PAT prompt, no shelling
   out, no helper script):
   - `POST https://github.com/login/device/code` with `client_id` and `scope`
     → returns `device_code`, `user_code`, `verification_uri`, `interval`.
   - Tell the user: open **`verification_uri`** and enter **`user_code`**.
   - Poll `POST https://github.com/login/oauth/access_token` every `interval`
     seconds (grant type `urn:ietf:params:oauth:grant-type:device_code`) until it
     returns an `access_token`.

   Send `Accept: application/json` to those two endpoints so the response is JSON.
   The skill's default client id is `Ov23liz5y2IEXIhpeOJk`. **If you can write
   files**, save the result to the cache path above (same format as
   `github-client`) so later runs reuse it; if you can't, keep the token for the
   session.
4. **Validate** a fresh token with a tiny GraphQL call (below). On `401`, the
   token is bad — refresh or re-run the device flow.

Only ever send the token to `api.github.com` (and `github.com` for the two login
endpoints). Never put it in a URL or echo it.

## The GraphQL request shape

One endpoint, always `POST`, body is `{ "query": ..., "variables": ... }`:

```
POST https://api.github.com/graphql
Authorization: Bearer <token>
Content-Type: application/json

{"query":"query{viewer{login}}"}
```

`viewer{login}` is the GraphQL equivalent of REST `GET /user` — use it to
validate a token. The response mirrors the query exactly:
`{"data":{"viewer":{"login":"..."}}}`. There is **no** `X-GitHub-Api-Version`
header on GraphQL.

**Checking for errors:** a malformed query or a field error comes back as
**HTTP 200** with a top-level `"errors"` array (and possibly partial `data`).
Always check for `errors` — 200 alone does not mean success. A bad token is
still `401`.

## Reading (GraphQL)

Pass variables in the `variables` object; list exactly the fields you want.
`references/graphql.md` has ready-to-use queries (recent issues, a PR with its
files, repo summary, file text, search) and the field vocabulary, which differs
from REST (`author{login}` not `user.login`, etc.). One example — 5 newest open
issues (the `issues` connection returns issues only, no PRs to filter):

```json
{"query":"query($o:String!,$n:String!,$k:Int!){repository(owner:$o,name:$n){issues(first:$k,states:OPEN,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number title author{login} comments{totalCount}}}}}","variables":{"o":"cli","n":"cli","k":5}}
```

**Pagination is cursor-based:** connections take `first:N`/`after:$cursor` and
return `pageInfo{endCursor hasNextPage}`; pass `endCursor` back as `after` until
`hasNextPage` is false.

## Writing (REST)

Writes return a single small object, so REST is fine here — read the fields you
need straight from the response. Send `Authorization: Bearer <token>`,
`Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, and
`Content-Type: application/json` with a JSON body.

| Operation | Method & path | Body |
| --- | --- | --- |
| Create issue | `POST /repos/{owner}/{repo}/issues` | `title` (req), `body`, `labels`, `assignees` |
| Update/close issue | `PATCH /repos/{owner}/{repo}/issues/{number}` | `title`, `body`, `state` (`open`/`closed`), `labels` |
| Comment | `POST /repos/{owner}/{repo}/issues/{number}/comments` | `body` (req) |
| Create PR | `POST /repos/{owner}/{repo}/pulls` | `title`, `head`, `base`, `body`, `draft` |
| Create/update file | `PUT /repos/{owner}/{repo}/contents/{path}` | `message`, `content` (base64), `sha` (when updating), `branch` |

The created/updated object comes back with fields like `number` and `html_url`.

## Rate limits

GraphQL has a **separate, point-based** budget (not request counts). Check it
inline: add `rateLimit{ limit cost remaining resetAt }` to any query, or send
`query{rateLimit{remaining resetAt}}`. Each call's `cost` scales with how many
nodes it could return, so request only the `first:N` you need. REST writes use
the REST limit; on `403`/`429` honor any `Retry-After` header.
