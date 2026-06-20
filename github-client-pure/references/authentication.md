# Authentication (pure HTTP)

This skill acquires and manages its own GitHub credentials using only HTTP
requests — no helper script, no PAT prompt, no shelling out. Order:
**environment token → cached token → OAuth device flow.** The core steps are in
`SKILL.md`; this file is the detail.

## Token cache

After a device-flow login, save the token so later runs reuse it. Check this
cache *before* starting the flow. It is **shared with the `github-client`
skill** — same path and format — so a login from either works for both.

- **Location:** `${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills/token.json`
- **Format:**

  ```json
  {
    "access_token": "gho_…",
    "token_type": "bearer",
    "scope": "repo,read:org",
    "expires_at": "2026-06-20T09:00:00Z",
    "refresh_token": "ghr_…",
    "refresh_token_expires_at": "2026-12-17T09:00:00Z"
  }
  ```

- If you can write files, write it user-private (mode `600`); never commit or log
  it. If the environment has no filesystem, just keep the token in memory for the
  session.
- `expires_at` / `refresh_token` exist only when the OAuth App has **token
  expiration** enabled. If `expires_at` is absent, treat the token as
  non-expiring and rely on a `401` to learn it was revoked.
- **Expiry check:** treat as expired when `now >= expires_at - 60s`.

## OAuth device flow (over HTTP)

A **client id is not a secret** and the device flow uses **no client secret**.
This skill ships a default registered OAuth App; `$GITHUB_OAUTH_CLIENT_ID`
defaults to `Ov23liz5y2IEXIhpeOJk`. To use your own, register an OAuth App with
**Device Flow** enabled and use its client id.

Send `Accept: application/json` to both endpoints so responses are JSON (the
default is form-encoded).

1. **Request a code:**

   ```
   POST https://github.com/login/device/code
   Accept: application/json
   Content-Type: application/x-www-form-urlencoded

   client_id=<CLIENT_ID>&scope=repo
   ```

   Response: `device_code`, `user_code`, `verification_uri`, `expires_in`,
   `interval`.

2. **Tell the user:** "Go to **<verification_uri>** and enter the code
   **<user_code>**."

3. **Poll for the token** every `interval` seconds:

   ```
   POST https://github.com/login/oauth/access_token
   Accept: application/json
   Content-Type: application/x-www-form-urlencoded

   client_id=<CLIENT_ID>&device_code=<DEVICE_CODE>&grant_type=urn:ietf:params:oauth:grant-type:device_code
   ```

   While `error` is `authorization_pending`, keep waiting; on `slow_down`,
   increase the interval; on success you get `access_token` (plus `expires_in`,
   `refresh_token`, `refresh_token_expires_in` when expiration is enabled).

4. **Save** to the cache, computing `expires_at = now + expires_in` (and likewise
   for the refresh token) when those fields are present.

## Refreshing an expired token

If the cached `access_token` is expired and a `refresh_token` is present:

```
POST https://github.com/login/oauth/access_token
Accept: application/json
Content-Type: application/x-www-form-urlencoded

client_id=<CLIENT_ID>&grant_type=refresh_token&refresh_token=<REFRESH_TOKEN>
```

You get a fresh `access_token` and `refresh_token`. Save them back. If refresh
fails (token expired/revoked), run the device flow again.

## Validating a token

GraphQL equivalent of `GET /user`:

```
POST https://api.github.com/graphql
Authorization: Bearer <token>
Content-Type: application/json

{"query":"query{viewer{login}}"}
```

- `200` with `data.viewer.login` → valid; that's the account.
- `401` → invalid or expired; refresh or re-run the device flow.

## Choosing scopes

Request the least the task needs, space-separated, in the device-flow `scope`:

| Task | Scope |
| --- | --- |
| Read public data | (none needed) |
| Read/write private repos, issues, PRs, file contents | `repo` |
| Read org membership/teams | `read:org` |
| Edit workflow files / manage Actions | `repo` plus `workflow` |
| Read user profile / email | `read:user` / `user:email` |

A token from `GITHUB_TOKEN` may be any valid GitHub token; its capabilities are
whatever it was granted.

## Auth errors

| Status | Meaning | Action |
| --- | --- | --- |
| `401` | Bad/expired/revoked token | Discard it; refresh if possible, else device flow |
| `200` + `errors` on a GraphQL call | Query/field/permission problem | Read the `errors[].message`; fix the query or request a broader scope |
| `403` + rate-limit headers (REST writes) | Rate limited | Honor `Retry-After`; wait for reset |

## Security checklist

- Request only the scopes the task needs; suggest revoking the grant when done.
- If you persist the token, store it user-private (`600`) at the cache path;
  never commit, log, echo, or embed it in a URL.
- Only send it to `api.github.com` (and `github.com` for the two login endpoints).
