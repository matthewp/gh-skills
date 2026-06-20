# GraphQL reads — query catalog

Every read is `POST https://api.github.com/graphql` with headers
`Authorization: Bearer <token>` and `Content-Type: application/json`, and a body
of `{ "query": "<query>", "variables": { ... } }`. The response is shaped exactly
like the query — already minimal, so no client-side filtering is needed.

Remember: a query/field error returns **HTTP 200 with a top-level `errors`
array**. Always check for `errors` before trusting `data`.

## Field vocabulary (differs from REST)

| Want | REST | GraphQL |
| --- | --- | --- |
| Issue/PR author | `user.login` | `author { login }` |
| Comment count | `comments` (number) | `comments { totalCount }` |
| Last few comments | `…/comments` call | `comments(last:5){ nodes{ author{login} body } }` |
| Labels | `labels[].name` | `labels(first:10){ nodes { name } }` |
| State | `state` (`open`/`closed`) | `state` enum (`OPEN`/`CLOSED`/`MERGED`) |
| Body | `body` | `body` (or `bodyText` for plain text) |
| File text | `contents/{path}` (base64) | `object(expression:"<ref>:<path>"){ ... on Blob { text } }` |
| Authed user | `GET /user` | `viewer { login }` |

## Queries

**Validate token / who am I:**

```graphql
query{ viewer{ login } }
```

**Recent open issues** (the `issues` connection returns issues only — no PRs):

```graphql
query($o:String!,$n:String!,$k:Int!){
  repository(owner:$o,name:$n){
    issues(first:$k,states:OPEN,orderBy:{field:CREATED_AT,direction:DESC}){
      nodes{ number title author{login} comments{totalCount} createdAt url }
    }
  }
}
```
variables: `{"o":"cli","n":"cli","k":5}`

**One issue with its body and recent comments:**

```graphql
query($o:String!,$n:String!,$num:Int!){
  repository(owner:$o,name:$n){
    issue(number:$num){
      number title state body author{login}
      labels(first:10){ nodes{ name } }
      comments(last:5){ nodes{ author{login} body } }
    }
  }
}
```

**One PR with its changed files:**

```graphql
query($o:String!,$n:String!,$num:Int!){
  repository(owner:$o,name:$n){
    pullRequest(number:$num){
      number title state isDraft author{login}
      baseRefName headRefName
      files(first:100){ nodes{ path additions deletions } }
    }
  }
}
```

**Repo summary:**

```graphql
query($o:String!,$n:String!){
  repository(owner:$o,name:$n){
    nameWithOwner description isPrivate stargazerCount
    primaryLanguage{name} defaultBranchRef{name} pushedAt url
  }
}
```

**Recent commits on a branch:**

```graphql
query($o:String!,$n:String!,$ref:String!,$k:Int!){
  repository(owner:$o,name:$n){
    ref(qualifiedName:$ref){
      target{ ... on Commit {
        history(first:$k){ nodes{ oid messageHeadline author{name date} } }
      }}
    }
  }
}
```
variables: `{"o":"cli","n":"cli","ref":"refs/heads/trunk","k":10}`

**A file's text** (no base64 round-trip):

```graphql
query($o:String!,$n:String!,$expr:String!){
  repository(owner:$o,name:$n){ object(expression:$expr){ ... on Blob { text } } }
}
```
variables: `{"o":"cli","n":"cli","expr":"HEAD:README.md"}` (`<ref>:<path>`)

**Search issues/PRs** (same qualifier syntax as REST search — see
`search-syntax.md`; `search` lets you select the fields, unlike REST):

```graphql
query($q:String!,$k:Int!){
  search(query:$q, type:ISSUE, first:$k){
    issueCount
    nodes{ ... on Issue { number title url repository{nameWithOwner} } }
  }
}
```
variables: `{"q":"repo:cli/cli is:issue is:open label:bug","k":5}`

## Pagination

Connections accept `first:N` and `after:$cursor`, and expose
`pageInfo{ endCursor hasNextPage }`:

```graphql
query($o:String!,$n:String!,$after:String){
  repository(owner:$o,name:$n){
    issues(first:50, after:$after, states:OPEN){
      pageInfo{ endCursor hasNextPage }
      nodes{ number title }
    }
  }
}
```

Pass the returned `endCursor` back as `$after` on the next call; stop when
`hasNextPage` is false.

## Rate limit

GraphQL is metered in points, not request counts. Append `rateLimit` to any
query to see your standing:

```graphql
query{ rateLimit{ limit cost remaining resetAt } }
```

`cost` rises with the number of nodes a call could return, so keep `first:N`
tight rather than fetching big pages and stopping early.
