# GitHub REST API — endpoint catalog

All paths are relative to `https://api.github.com`. Send the standard headers:
`Authorization: Bearer $GITHUB_TOKEN`, `Accept: application/vnd.github+json`,
`X-GitHub-Api-Version: 2022-11-28`. In a shell, `scripts/api.sh <path> -q <filter>`
sends these and trims the response for you.

## Useful fields (select these, ignore the rest)

Responses carry ~30 fields per object; these are the ones worth keeping. Pass
them to `jq`/`-q` (e.g. `-q '[.[]|{number,title,state}]'`) so you read only them.

| Resource | Commonly useful fields |
| --- | --- |
| Issue / PR | `number`, `title`, `state`, `body`, `.user.login`, `.labels[].name`, `comments`, `created_at`, `updated_at`, `html_url`; PRs also `draft`, `merged`, `.base.ref`, `.head.ref` |
| Repo | `full_name`, `description`, `private`, `default_branch`, `stargazers_count`, `open_issues_count`, `language`, `pushed_at`, `html_url` |
| Commit | `sha`, `.commit.message`, `.commit.author.name`, `.commit.author.date`, `.author.login` |
| Workflow run | `id`, `name`, `status`, `conclusion`, `event`, `.head_branch`, `created_at`, `html_url` |
| Contents (file) | `name`, `path`, `sha`, `size`, `content` (base64) — or fetch with `--raw` for bytes |
| Search result | top level `total_count`; then trim each `.items[]` like its underlying resource |
| User | `login`, `name`, `type`, `html_url` |

## Issues

| Operation | Method & path | Key params |
| --- | --- | --- |
| List repo issues | `GET /repos/{owner}/{repo}/issues` | `state` (open/closed/all), `sort` (created/updated/comments), `direction` (asc/desc), `labels`, `assignee`, `creator`, `since`, `per_page`, `page` |
| Get one issue | `GET /repos/{owner}/{repo}/issues/{number}` | — |
| Create issue | `POST /repos/{owner}/{repo}/issues` | body: `title` (required), `body`, `labels`, `assignees` |
| Update issue | `PATCH /repos/{owner}/{repo}/issues/{number}` | body: `title`, `body`, `state` (open/closed), `labels` |
| List comments | `GET /repos/{owner}/{repo}/issues/{number}/comments` | `per_page`, `page` |
| Add comment | `POST /repos/{owner}/{repo}/issues/{number}/comments` | body: `body` (required) |

Note: the list-issues endpoint returns pull requests too. Each PR item carries a
`pull_request` object; skip those if you only want issues.

## Pull requests

| Operation | Method & path | Key params |
| --- | --- | --- |
| List PRs | `GET /repos/{owner}/{repo}/pulls` | `state`, `head`, `base`, `sort`, `direction`, `per_page` |
| Get one PR | `GET /repos/{owner}/{repo}/pulls/{number}` | — |
| List changed files | `GET /repos/{owner}/{repo}/pulls/{number}/files` | `per_page`, `page` |
| List reviews | `GET /repos/{owner}/{repo}/pulls/{number}/reviews` | — |
| Create PR | `POST /repos/{owner}/{repo}/pulls` | body: `title`, `head`, `base`, `body`, `draft` |

## Repositories

| Operation | Method & path | Key params |
| --- | --- | --- |
| Get repo | `GET /repos/{owner}/{repo}` | — |
| List a user's repos | `GET /users/{username}/repos` | `type`, `sort`, `direction`, `per_page` |
| List an org's repos | `GET /orgs/{org}/repos` | `type`, `sort`, `per_page` |
| List your repos | `GET /user/repos` | `visibility`, `affiliation`, `sort`, `per_page` |
| List branches | `GET /repos/{owner}/{repo}/branches` | `per_page` |
| List tags | `GET /repos/{owner}/{repo}/tags` | `per_page` |

## Commits & comparison

| Operation | Method & path | Key params |
| --- | --- | --- |
| List commits | `GET /repos/{owner}/{repo}/commits` | `sha` (branch/sha), `path`, `author`, `since`, `until`, `per_page` |
| Get one commit | `GET /repos/{owner}/{repo}/commits/{ref}` | returns files + stats |
| Compare two refs | `GET /repos/{owner}/{repo}/compare/{base}...{head}` | diff/ahead-behind between refs |

## Contents

| Operation | Method & path | Notes |
| --- | --- | --- |
| Get file/dir | `GET /repos/{owner}/{repo}/contents/{path}` | `ref` selects branch/tag/sha. File `content` is base64; or send `Accept: application/vnd.github.raw` for raw bytes |
| Create/update file | `PUT /repos/{owner}/{repo}/contents/{path}` | body: `message`, `content` (base64), `sha` (required when updating), `branch` |

## Actions (CI)

| Operation | Method & path | Key params |
| --- | --- | --- |
| List workflow runs | `GET /repos/{owner}/{repo}/actions/runs` | `branch`, `status`, `event`, `per_page` |
| Get one run | `GET /repos/{owner}/{repo}/actions/runs/{run_id}` | — |
| List a run's jobs | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs` | `per_page` |
| Download run logs | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs` | redirects to a zip of logs |

## Users

| Operation | Method & path | Notes |
| --- | --- | --- |
| Authenticated user | `GET /user` | who the token belongs to |
| A user | `GET /users/{username}` | public profile |

## Search (separate, lower rate limit)

| Operation | Method & path | Returns |
| --- | --- | --- |
| Search issues & PRs | `GET /search/issues?q=...` | `{ total_count, incomplete_results, items }` |
| Search repos | `GET /search/repositories?q=...` | repos matching the query |
| Search code | `GET /search/code?q=...` | code matches (needs auth) |
| Search commits | `GET /search/commits?q=...` | commit matches |

Search also accepts `sort`, `order` (asc/desc), `per_page`, `page`. Results cap
at 1,000 items. See `search-syntax.md` for query qualifiers.
