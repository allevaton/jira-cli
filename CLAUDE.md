# CLAUDE.md

`jira-cli` is an interactive Go/Cobra command-line tool for Atlassian Jira, modelled on GitHub's `gh`. It targets two kinds of Jira that differ in API version, text format, and auth — a split that reaches nearly every feature.

## Vocabulary

- **Installation type** — which Jira a user is on: `Cloud` or `Local`. `Local` means self-hosted Server/Data Center, *not* localhost or a dev instance. Stored as config key `installation`; it selects API version and body format everywhere.
- **ADF** (Atlassian Document Format) — Cloud's rich-text JSON representation of issue bodies. `pkg/adf` converts it to and from markdown.
- **Jira wiki markup** — the plain-text markup `Local` installations use for the same bodies, parsed by `pkg/md/jirawiki`.
- **Epic field** — the instance-specific `customfield_*` ID behind the human labels "Epic Name" and "Epic Link". Every instance numbers them differently; they are resolved from create metadata, never assumed.
- **Handle** — an untranslated issue-type name recorded in config (`issue.types.*.handle`). Non-English instances return localised type names, so the handle is what the code matches on.

## Fork workflow

`origin` = `allevaton/jira-cli`, `upstream` = `ankitpokhrel/jira-cli`. Work lives on `local`; `main` tracks upstream. `scripts/sync-fork.sh`, run from your work branch, fetches upstream, fast-forwards `main`, pushes it to `origin`, and rebases your branch onto it — bailing if `main` diverged or the tree is dirty. The rebase rewrites history, so follow it with `git push --force-with-lease origin <branch>`. PRs to the original project target upstream `main`.

`local` is personal-only: it carries changes for my own workflow, is not meant for other users, and never goes upstream. A change belongs on `local` unless it's a fix meant for upstream, in which case branch it off `main` instead and PR it to `ankitpokhrel/jira-cli`.

## Architecture

Three layers, with a hard rule at each seam:

1. **`pkg/jira/`** — the API client, and the only place that speaks HTTP to Jira. It takes a `jira.Config` and knows nothing of Cobra or viper, which is what makes it testable against `testdata/` fixtures. One file per domain; `client.go` holds the `Client`, auth, error types (`ErrUnexpectedResponse`, `ErrNoResult`), and the base-URL constants (`/rest/api/3` Cloud, `/rest/api/2` Local, `/rest/agile/1.0` boards and sprints).
2. **`internal/`** — everything CLI-shaped. `internal/cmd/<group>/<subcommand>/` mirrors the command tree one directory per command (`jira issue create` → `internal/cmd/issue/create/`), each exposing one `NewCmd<Name>()` wired into its parent up to `internal/cmd/root/`. `internal/query/` turns flags into API params behind the `FlagParser` interface, so query building is testable without a live command. `internal/view/` renders responses, delegating interactive tables to `pkg/tui`.
3. **`api/`** — the bridge. `api.Client()` assembles a `pkg/jira` client from viper, `.netrc`, and the OS keyring, in that fallback order. Commands call `api.DefaultClient(debug)`.

Typical request: `cmd/jira/main.go` → root → subcommand `Run` → `internal/query` → `api.DefaultClient()` → `pkg/jira` → `internal/view`.

### The Proxy seam

`api/client.go` exposes a family of **Proxy functions** — `ProxyCreate`, `ProxySearch`, `ProxyGetIssue`, `ProxyGetIssueRaw`, `ProxyAssignIssue`, `ProxyUserSearch`, `ProxyTransitions`, `ProxyWatchIssue`. Each reads `installation` and dispatches to the `…V2` method for `Local` or the v3 method otherwise, defaulting to v3 when the value is unset. Route every version-split call through a Proxy function, and add one when you add a version-split endpoint; calling `c.Create` or `c.Search` directly silently breaks `Local` users.

The two search paths differ in shape, not just version: v3 `Search(jql, limit)` hits `/search/jql`, which has no offset parameter at all, while v2 `SearchV2(jql, from, limit)` hits the paginated `/search?startAt=…`. `ProxySearch` accepts `from` and drops it on Cloud. Treat offset pagination as v2-only.

## Gotchas

- **The client is a cached singleton, and the first call wins.** `api.Client()` stores it in a package-level `var jiraClient` and returns that on every later call, ignoring the `jira.Config` passed in. Production builds it once; tests needing a distinct config must reset or work around it.
- **A stale `vendor/` hijacks every `go` command.** `vendor/` is gitignored, but `make build` runs `go mod vendor` first and thereby creates it — and Go auto-switches to `-mod=vendor` whenever it exists. After changing `go.mod`, re-run `make deps`, or plain `go build`/`go test` keeps resolving against the old tree.
- **`-race` needs CGO, which the Makefile disables globally.** The Makefile exports `CGO_ENABLED ?= 0` for builds and re-enables it only inside `test`. A new make target that runs `go test -race` inherits the `0` and fails to build the race detector.
- **The JQL builder joins filters only inside `And`/`Or`.** Filters accumulate in a flat slice, and `And(fn)`/`Or(fn)` run the closure then merge what it added with a single separator. Add filters inside the closure (see `internal/query/issue.go`); those left outside reach `compile()` unmerged and are space-joined into invalid JQL. The builder also has no parenthesised grouping and validates nothing.
- **The jirawiki parser indexes bytes, not runes.** `pkg/md/jirawiki` walks `line[i]` as bytes; multibyte UTF-8 survives only because the code writes bytes straight through. Keep byte semantics when editing it — converting an index to a `rune` corrupts non-ASCII text.
- **Version vars are empty in source.** `internal/version` ships `Version = "v0.0.0-dev"` and an empty `GitCommit`; real values come from `-ldflags` via `make build`/`make install`. A bare `go build` yielding a dev version is expected.
- **Datetimes take IANA zone names.** `cmdutil.DateStringToJiraFormatInLocation` resolves through `time.LoadLocation`, which accepts `Europe/Berlin` and rejects offsets like `+05:00`.
- **Config home follows `XDG_CONFIG_HOME`.** `cmdutil.GetConfigHome()` returns it when set and falls back to `~/.config`; config lands at `<home>/.jira/.config.yml`. Precedence is `--config` > `JIRA_CONFIG_FILE` > that default, and every key is also readable as a `JIRA_`-prefixed env var (viper `AutomaticEnv`). The API token stays out of the config file — it comes from `JIRA_API_TOKEN`, `.netrc`, or the keyring.

## Working across installation types

When you add or change a feature, decide how it behaves on each installation type and handle both. Cloud means API v3 and ADF bodies; `Local` means v2, wiki markup, and an older Agile API. Auth types are `basic` (Cloud's usual: email + API token), `bearer` (PAT), `mtls`, and `cf-access` (Cloudflare Access, which wraps the transport in a token-fetching round tripper). Note that `pkg/jira`'s per-request auth switch handles basic, bearer, and mtls — `cf-access` does its work at transport construction instead.

Epic fields resolve per instance from create metadata. On non-English `Local` instances the older API omits untranslated `issuetype` names, so `jira init` cannot resolve them and the user hand-fills `epic.name`, `epic.link`, and the type handles (see README). Resolve these IDs from metadata or config.

## Conventions

- One `NewCmd<Name>() *cobra.Command` per subcommand package; define flags there and read them back through `internal/query`.
- User-facing failures go through `cmdutil.Failed(...)`, which prints and exits; `pkg/jira` returns typed errors instead.
- New API interactions belong in `pkg/jira` with a sibling `_test.go` over `testdata/` JSON — keep HTTP out of command code.
- Build, lint, and test through the Makefile; it is the source of truth for tool versions and flags.
