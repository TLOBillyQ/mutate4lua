# Issue tracker: Gitea (self-hosted)

Issues and specs for this repo live in Gitea Issues at `http://lzxsvn:3000/qinyuanj/mutate4lua`. Use the [`tea`](https://gitea.com/gitea/tea) CLI (login `lzxsvn`, user `qinyuanj`) for all operations; use `tea api` for authenticated API calls the CLI does not cover.

## Conventions

- **Create an issue**: `tea issues create --title "..." --description "..." --labels a,b`. Use a heredoc for multi-line descriptions.
- **Read an issue**: `tea api repos/{owner}/{repo}/issues/<index>` for the body, `tea comments list <index>` for comments.
- **List issues**: `tea issues list --state open --labels <label>`; for machine-readable output use `tea api 'repos/{owner}/{repo}/issues?state=open&type=issues'`.
- **Comment on an issue**: `tea comments add <index> "..."`.
- **Apply / remove labels**: `tea issues edit <n> --add-labels "..."` / `--remove-labels "..."`. Create labels with `tea labels create <name> --color <hex>`.
- **Assign**: `tea issues edit <n> --add-assignees qinyuanj`.
- **Close**: `tea issues close <n>`. Post the resolution comment first with `tea comments add <n> "..."`, then close.
- **Pull requests**: `tea pulls ...` mirrors the issues surface.

Infer the repo from `git remote -v` — `tea` does this automatically when run inside a clone; pass `--repo qinyuanj/mutate4lua` otherwise.

## PRs as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external pull requests as feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

Create a Gitea issue.

## When a skill says "fetch the relevant ticket"

Run `tea api repos/{owner}/{repo}/issues/<index>` plus `tea comments list <index>`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `tea issues create --label wayfinder:map`.
- **Child ticket**: an issue carrying `Part of #<map>` at the top of its description and labels `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: Gitea's **native issue dependencies** — the canonical, UI-visible representation ("Blocked by" in the web UI). Add with `tea api -X POST repos/<owner>/<repo>/issues/<blocked>/dependencies -F index=<blocker> -f owner=<owner> -f repo=<repo>` (the `IssueMeta` body requires all three fields; omitting owner/repo yields a misleading "repository does not exist"). List a ticket's blockers with `tea api repos/<owner>/<repo>/issues/<n>/dependencies`. Use explicit `qinyuanj/mutate4lua` paths — `{owner}/{repo}` placeholders are unreliable for POSTs. If this endpoint is unavailable on the server, fall back to a `Blocked by: #<n>, #<n>` line at the top of the description. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children, drop any with an open blocker (native dependency to an open issue, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `tea issues edit <n> --add-assignees qinyuanj` — the session's first write.
- **Resolve**: `tea comments add <n> "<answer>"`, then `tea issues close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
