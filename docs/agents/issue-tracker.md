# Issue tracker: GitHub (REST, not `gh`)

Issues and specs live as GitHub issues on **`Blueprint-Agency/infrastructure`** (renamed from
`teeko-infrastructure`; the old API path answers `301` with no body, which reads as an empty issue).
There is **no `gh` CLI installed** — use `curl` + the REST API, per the repo's credentials
rule. The PAT is `GITHUB_PERSONAL_ACCESS_TOKEN` in `.env`.

> ⚠️ This PAT can also see **`Inquantum-AI`**, a different client's org. Confirm the
> `owner/repo` in the URL before any write.

```bash
TOKEN=$(grep -m1 '^GITHUB_PERSONAL_ACCESS_TOKEN=' .env | cut -d= -f2-)
API="https://api.github.com/repos/Blueprint-Agency/infrastructure"
gh_api() { curl -sS -H "Authorization: Bearer $TOKEN" \
                    -H "Accept: application/vnd.github+json" "$@"; }
```

## Conventions

- **Create an issue**: `gh_api -X POST "$API/issues" -d @-` with a
  `{"title", "body", "labels"}` heredoc, so multi-line bodies survive.
- **Read an issue**: `gh_api "$API/issues/<n>"` plus `gh_api "$API/issues/<n>/comments"` —
  two calls; REST does not inline comments the way `gh issue view --comments` does.
- **List issues**: `gh_api "$API/issues?state=open&per_page=100&labels=<label>"`
- **Comment**: `gh_api -X POST "$API/issues/<n>/comments" -d '{"body":"..."}'`
- **Apply / remove labels**: `gh_api -X POST "$API/issues/<n>/labels" -d '{"labels":["..."]}'`
  / `gh_api -X DELETE "$API/issues/<n>/labels/<label>"`
- **Close**: comment first, then `gh_api -X PATCH "$API/issues/<n>" -d '{"state":"closed"}'`

> **`GET /issues` returns pull requests too.** `gh issue list` hides them; REST does not.
> Filter with `jq '[.[] | select(.pull_request | not)]'`, or every open PR shows up as an
> issue in the triage queue.

> **Always pass `per_page=100`.** The default is 30 and truncates silently — a short list
> reads as "that's all of them".

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature
requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues:

- **List external PRs**: `gh_api "$API/pulls?state=open&per_page=100"`, then keep only
  `author_association` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE`
  (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Diff**: the same `$API/pulls/<n>` URL with `-H "Accept: application/vnd.github.v3.diff"`.
- **Comment / label / close**: use the **issues** endpoints — a PR is an issue for those.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either — try
`$API/pulls/42` and fall back to `$API/issues/42`.

## When a skill says "publish to the issue tracker"

`POST $API/issues`.

## When a skill says "fetch the relevant ticket"

`GET $API/issues/<n>` plus `GET $API/issues/<n>/comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: one issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue —
  `gh_api -X POST "$API/issues/<map>/sub_issues" -d '{"sub_issue_id":<db-id>}'`. Labels:
  `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Where sub-issues aren't
  enabled, add the child to a task list in the map body and put `Part of #<map>` at the top
  of the child body.
- **Blocking**: GitHub's native issue dependencies —
  `gh_api -X POST "$API/issues/<child>/dependencies/blocked_by" -d '{"issue_id":<db-id>}'`.
  A ticket is unblocked when every blocker is closed; GitHub reports open blockers as
  `issue_dependencies_summary.blocked_by`.
- **`<db-id>` is the numeric `.id`**, not the `#number` and not the `node_id`:
  `gh_api "$API/issues/<n>" | jq .id`. Both endpoints accept a wrong-but-valid id happily
  and link the wrong issue.
- **Frontier query**: the map's open children, dropping any with
  `issue_dependencies_summary.blocked_by > 0` or an assignee; first in map order wins.
- **Claim**: `gh_api -X PATCH "$API/issues/<n>" -d '{"assignees":["chriskke"]}'` — the
  session's first write.
- **Resolve**: comment the answer, close the issue, then append a context pointer to the
  map's Decisions-so-far.
