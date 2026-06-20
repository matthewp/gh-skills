# GitHub search query syntax (`/search/issues`)

Build the `q` parameter from space-separated terms and `qualifier:value` pairs.
URL-encode it (spaces → `+` or `%20`). Combine free text with qualifiers:
`q=memory+leak+repo:vercel/next.js+is:open`.

## Scope

| Qualifier | Meaning |
| --- | --- |
| `repo:owner/name` | Limit to one repository |
| `org:name` / `user:name` | Limit to an org / user's repos |
| `is:issue` / `is:pr` | Only issues, or only pull requests |
| `is:open` / `is:closed` | By state |
| `is:merged` / `is:unmerged` | PRs only |
| `draft:true` / `draft:false` | PR draft state |
| `archived:true/false` | Include/exclude archived repos |

## People

| Qualifier | Meaning |
| --- | --- |
| `author:login` | Opened by this user |
| `assignee:login` | Assigned to this user |
| `mentions:login` | Mentions this user |
| `commenter:login` | Commented by this user |
| `involves:login` | Author, assignee, mentioner, or commenter |
| `review-requested:login` | PRs requesting this reviewer |

## Labels, milestones, content

| Qualifier | Meaning |
| --- | --- |
| `label:"bug"` | Has this label (quote multi-word labels; repeat for AND) |
| `milestone:"v2.0"` | In this milestone |
| `in:title` / `in:body` / `in:comments` | Restrict free-text match location |
| `no:label` / `no:assignee` / `no:milestone` | Missing that field |

## Numbers & dates

Use ranges with `>`, `>=`, `<`, `<=`, or `A..B`. Dates are ISO 8601.

| Qualifier | Example |
| --- | --- |
| `created:` | `created:>=2026-01-01` |
| `updated:` | `updated:<2026-06-01` |
| `closed:` | `closed:2026-01-01..2026-03-31` |
| `comments:` | `comments:>10` |
| `reactions:` | `reactions:>100` |
| `interactions:` | `interactions:>50` |

## Sorting

Add outside `q`: `&sort=` one of `created`, `updated`, `comments`,
`reactions`, `reactions-+1`, etc., and `&order=asc|desc` (default `desc`).
Without `sort`, results come back by best match.

## Worked examples

| Intent | `q` (before URL-encoding) |
| --- | --- |
| Open bugs in a repo, newest first | `repo:vercel/next.js is:issue is:open label:bug` + `&sort=created&order=desc` |
| PRs awaiting my review | `is:pr is:open review-requested:@me` |
| Issues I opened, still open | `is:issue is:open author:@me` |
| Stale issues (no update since Jan) | `repo:facebook/react is:issue is:open updated:<2026-01-01` |
| Most-discussed open issues | `repo:rust-lang/rust is:issue is:open` + `&sort=comments&order=desc` |

`@me` resolves to the authenticated token's user.
