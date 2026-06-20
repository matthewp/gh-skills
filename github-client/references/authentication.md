# Authentication

This skill acquires and manages its own GitHub credentials, in this order:
**environment token → cached token → OAuth device flow.** It does not ask for a
Personal Access Token and does not shell out to other tools. The core steps are
in `SKILL.md`; this file is the detail.

## Token cache

After an OAuth login, save the token so later runs reuse it instead of logging in
again. Check this cache *before* starting the device flow.

- **Location:** `${XDG_CONFIG_HOME:-$HOME/.config}/gh-skills/token.json`
- **Permissions:** create the directory and file as user-only and `chmod 600` the
  file. It holds a live credential — never commit it or write it to a shared path.
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

- `expires_at` / `refresh_token` exist only when the OAuth App has **token
  expiration** enabled. If `expires_at` is absent or null, treat the token as
  non-expiring and rely on a `401` to learn it was revoked.
- **Expiry check:** treat the token as expired when `now >= expires_at - 60s`
  (a small clock skew). If expired, refresh before falling back to a new login.

## OAuth login — device flow (this client runs it)

This skill is a standalone GitHub client, an alternative to `gh` — not a wrapper.
It performs the OAuth flow itself by calling GitHub's auth endpoints directly. A
**client id is not a secret** and the device flow uses **no client secret**.

This skill ships with its own registered OAuth App, so `$GITHUB_OAUTH_CLIENT_ID`
**defaults to gh-skills's public client id `Ov23liz5y2IEXIhpeOJk`**. To use your
own app instead, register one (Settings → Developer settings → OAuth Apps → New),
enable **Device Flow**, and set `GITHUB_OAUTH_CLIENT_ID` to its client id.

**Quick login:** run `scripts/login.sh` — it requests the code, prints the URL
and code, polls, and writes the token cache for you. The steps below are the
manual equivalent; to run them by hand, first
`export GITHUB_OAUTH_CLIENT_ID=Ov23liz5y2IEXIhpeOJk`.

1. **Request a code:**

   ```bash
   curl -sS -X POST https://github.com/login/device/code \
     -H "Accept: application/json" \
     -d "client_id=$GITHUB_OAUTH_CLIENT_ID" -d "scope=repo read:org"
   ```

   Response: `device_code`, `user_code`, `verification_uri`, `expires_in`, `interval`.

2. **Tell the user:** "Go to **<verification_uri>** and enter the code **<user_code>**."

3. **Poll for the token** every `interval` seconds:

   ```bash
   curl -sS -X POST https://github.com/login/oauth/access_token \
     -H "Accept: application/json" \
     -d "client_id=$GITHUB_OAUTH_CLIENT_ID" -d "device_code=$DEVICE_CODE" \
     -d "grant_type=urn:ietf:params:oauth:grant-type:device_code"
   ```

   Keep polling while `error` is `authorization_pending`; on `slow_down` increase
   the interval. On success you get `access_token` (plus `expires_in`,
   `refresh_token`, `refresh_token_expires_in` when expiration is enabled).

4. **Save** the result to the token cache, computing `expires_at = now +
   expires_in` (and likewise for the refresh token) when those fields are present.

The two `github.com/login/...` endpoints are the only hosts other than
`api.github.com` this skill talks to.

## Refreshing an expired token

If the cached `access_token` is expired and a `refresh_token` is present, refresh
instead of doing a full login:

```bash
curl -sS -X POST https://github.com/login/oauth/access_token \
  -H "Accept: application/json" \
  -d "client_id=$GITHUB_OAUTH_CLIENT_ID" \
  -d "grant_type=refresh_token" -d "refresh_token=$REFRESH_TOKEN"
```

You get a new `access_token` and `refresh_token` (with fresh `expires_in`). Save
them back to the cache. If the refresh fails (refresh token expired or revoked),
run the device flow again.

## Choosing scopes

Request the least the task needs, space-separated, in the device-flow `scope`:

| Task | Scope |
| --- | --- |
| Read public data | (none needed) |
| Read/write private repos, issues, PRs, file contents | `repo` |
| Read org membership/teams | `read:org` |
| Edit workflow files / manage Actions | `repo` plus `workflow` |
| Read user profile / email | `read:user` / `user:email` |

A token supplied via `GITHUB_TOKEN` may be any valid GitHub token (PAT or OAuth);
its capabilities are whatever it was granted.

## Validating & inspecting a token

```bash
curl -sS https://api.github.com/user \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json"
```

- `200` → valid; the body's `login` is the account.
- The `x-oauth-scopes` response header lists the token's granted scopes.
- `401` → invalid or expired; refresh or re-run the device flow.

## Auth-related errors

| Status | Meaning | Action |
| --- | --- | --- |
| `401` | Bad/expired/revoked token | Delete the cache; refresh if possible, else device flow |
| `403` + rate-limit headers | Rate limited | Wait for `X-RateLimit-Reset`; respect `Retry-After` |
| `403` "resource not accessible by integration" | Token lacks a needed scope | Re-login requesting that scope |
| `404` on something you expect to exist | Often private + insufficient access | Ensure the token's scopes cover that repo/org |

## Security checklist

- Request only the scopes the task needs.
- Store the token at the user-private cache path with `600` permissions; never
  commit, log, echo, or embed it in a URL.
- Only send it to `api.github.com` (and `github.com` for the login endpoints).
- Suggest the user revoke the OAuth grant when the work is done.
