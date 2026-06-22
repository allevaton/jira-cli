# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`jira-cli` is an interactive command-line tool for Atlassian Jira (a Go/Cobra CLI, heavily inspired by GitHub's `gh`). It supports both Jira Cloud and on-premise (Server/Data Center) installations, which differ in API version and data formats — see "Cloud vs. on-premise" below.

## Commands

```sh
make build      # go build with version ldflags (vendors deps first)
make install    # go install into $GOPATH/bin
make lint       # golangci-lint (auto-installs v2.6.2 if missing)
make test       # go clean -testcache && CGO_ENABLED=1 go test -race ./...
make ci         # lint + test (what CI runs)
make jira.server  # docker compose up -d (local Jira for manual testing)
```

Run a single test:
```sh
go test -race ./pkg/jira/ -run TestGetIssue
go test -race ./internal/query/ -run '^TestIssueGet$'   # anchor the regex to run exactly one test
```

Tests require `CGO_ENABLED=1` because of the `-race` flag. Dependencies are **vendored** (`vendor/`), so `make deps` (`go mod vendor`) must be run after changing `go.mod`.

## Fork workflow

This is a fork (`origin` = `allevaton/jira-cli`, `upstream` = `ankitpokhrel/jira-cli`). Personal work lives on the `local` branch; `main` tracks upstream. Run `scripts/sync-fork.sh` from your work branch: it fetches `upstream`, fast-forwards `main` to `upstream/main`, pushes `main` to `origin`, then rebases the current branch onto `main` (it bails if `main` diverged or the tree is dirty). Because the rebase rewrites history, update the remote branch afterward with `git push --force-with-lease origin <branch>`. PRs to the original project target upstream `main`.

## Architecture

The codebase has a strict three-layer separation:

1. **`pkg/jira/`** — the Jira API client and the only place that talks HTTP to Jira. Each file maps to a domain (`issue.go`, `epic.go`, `sprint.go`, `board.go`, `search.go`, `transition.go`, etc.). `client.go` holds the `Client` struct, auth handling (basic / bearer / mtls), error types (`ErrUnexpectedResponse`, `ErrNoResult`), and API version constants (`/rest/api/3` for Cloud, `/rest/api/2` for on-premise, `/rest/agile/1.0` for boards/sprints). `types.go` holds the response structs. This package has **no dependency on Cobra/viper** — it takes a `jira.Config` and is independently testable (see `*_test.go` with `testdata/` fixtures).

2. **`internal/`** — everything CLI-specific:
   - `internal/cmd/<group>/<subcommand>/` — one directory per Cobra command, mirroring the CLI structure (`jira issue create` → `internal/cmd/issue/create/`). Each defines a `NewCmd<Name>()` constructor wired up in the parent's command file, ultimately in `internal/cmd/root/root.go`.
   - `internal/query/` — translates Cobra flags into API query params. `FlagParser` is an interface wrapping `pflag.FlagSet` so query construction is testable without a real command.
   - `internal/view/` — renders API responses to the terminal (tables, issue detail views). The interactive table UI delegates to `pkg/tui`.
   - `internal/config/generator.go` — drives `jira init`, probing the server and writing the YAML config.
   - `internal/cmdutil/` — shared CLI helpers (`Failed()`, config-home resolution, datetime formatting).
   - `internal/cmdcommon/` — flag sets shared across create-style commands (`SetCreateFlags`).

3. **`api/client.go`** — a thin singleton bridge. `api.Client()` / `api.DefaultClient()` reads config from viper, the `.netrc` file, and the OS keyring (in that fallback order) and constructs the `pkg/jira` client. Commands call `api.DefaultClient(debug)` rather than building a client themselves.

### Supporting `pkg/` libraries
- `pkg/adf/` — converts Atlassian Document Format (Cloud's rich-text JSON) to/from markdown. Cloud issue bodies are ADF; on-premise uses wiki markup.
- `pkg/md/jirawiki/` — Jira wiki-markup parsing (on-premise text format).
- `pkg/jql/` — a minimal JQL query builder. **Limitation: it cannot mix AND and OR in one query** and does no syntax validation — the caller must build a valid query.
- `pkg/tui/` — the interactive terminal UI (tables, previews) built on `tview`/`tcell`. `pkg/tui/primitive/` has custom widgets.
- `pkg/surveyext/` — extensions to the `survey` prompt library for interactive input.
- `pkg/netrc/`, `pkg/browser/` — `.netrc` parsing and cross-platform browser opening.

### Request flow for a typical command
`cmd/jira/main.go` → `root.NewCmdRoot()` → subcommand `Run` func → parse flags via `internal/query` → `api.DefaultClient()` → `pkg/jira` method → render with `internal/view` (+ `pkg/tui` for interactive output).

## Cloud vs. on-premise

This distinction pervades the code. Config field `installation` is `Cloud` or `Local`. Cloud uses API v3 + ADF rich text; on-premise uses API v2 + wiki markup and an older Agile API. When adding or changing a feature, check whether it behaves differently per installation type and handle both. Auth types also differ: Cloud typically uses `basic` (email + API token), on-premise uses `basic`, `bearer` (PAT), or `mtls`.

## Configuration

Config precedence (handled in `root.go` `init()`): `--config` flag > `JIRA_CONFIG_FILE` env > default `<config-home>/.jira/.config.yml`. All keys are also readable from `JIRA_`-prefixed env vars (viper `AutomaticEnv`). The API token is never stored in the config file — it comes from `JIRA_API_TOKEN`, `.netrc`, or the OS keyring.

## Common gotchas

- **The API client is a cached singleton.** `api.Client()` stores the client in a package-level `var jiraClient` and returns it on every subsequent call, ignoring the passed-in `jira.Config`. The first call wins. Tests that need different configs (or a fresh client) must account for this; production code only ever builds it once.
- **Issue creation is version-routed, not endpoint-uniform.** `api.ProxyCreate` dispatches to the v2 or v3 POST `/issue` endpoint based on the `installation` config value, **defaulting to v3 when unset**. Don't call a fixed-version create path directly — go through `ProxyCreate` so on-premise (v2) keeps working.
- **Two different search endpoints.** `pkg/jira/search.go` uses the newer `/search/jql` (Cloud, `maxResults` only) and the older paginated `/search?startAt=…&maxResults=…`. They page differently — match the one already used for the installation type rather than assuming `startAt` pagination everywhere.
- **Epic fields are dynamic custom fields.** "Epic Name" / "Epic Link" map to instance-specific `customfield_*` IDs resolved from create metadata (`EpicField`). On non-English on-premise instances the older API doesn't return untranslated `issuetype` names, so `jira init` can't auto-resolve them — the user must hand-fill `epic.name`, `epic.link`, and `issue.types.*.handle` in the config (see README). Don't hard-code custom field IDs.
- **Version vars are empty in source.** `internal/version` ships `Version = "v0.0.0-dev"`, `GitCommit = ""`; the real values are injected via `-ldflags` by `make build`/`make install` (and fall back to the Go module version). `go build` without the Makefile produces a dev-versioned binary — expected, not a bug.
- **`go.mod` is authoritative for the Go version** (currently 1.25) over anything stated elsewhere. Deps are vendored, so run `make deps` (`go mod vendor`) after touching `go.mod` or CI/build will drift.
- **Race tests need CGO.** `make test` sets `CGO_ENABLED=1`; a bare `go test -race ./...` with CGO disabled will fail to build the race detector.
- **Timezones must be IANA strings.** Datetime parsing (`cmdutil.DateStringToJiraFormatInLocation`) uses `time.LoadLocation` and rejects anything that isn't a valid IANA zone (e.g. `Europe/Berlin`), not offsets like `+05:00`.
- **Config home respects `XDG_CONFIG_HOME`.** `cmdutil.GetConfigHome()` returns `$XDG_CONFIG_HOME` if set, otherwise `~/.config`; the config then lives under `<home>/.jira/.config.yml`. Don't assume `~/.config`.

## Conventions

- Each subcommand package exposes a single `NewCmd<Name>() *cobra.Command` constructor; flags are defined there and read back via `internal/query`.
- Errors bound for the user go through `cmdutil.Failed(...)` (prints and exits); library errors in `pkg/jira` are returned as typed errors.
- New API interactions belong in `pkg/jira`, with a sibling `_test.go` using `testdata/` JSON fixtures — never embed HTTP calls in command code.
