# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Keep machine- or organization-specific project lists in a local workflow file outside the checked-out Symphony repo, for example `~/.config/symphony/WORKFLOW.md`. The in-repo `WORKFLOW.md` is intended as a reusable template.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  backend: codex
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
claude:
  command: claude
  model: claude-opus-4-8
  effort: high
  permission_mode: bypassPermissions
  env_file: ~/.config/symphony/anthropic.env
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.backend` selects the coding agent Symphony runs each turn: `codex` (default) drives the
  Codex app-server, `claude` runs Claude Code in non-interactive `--print` mode via the `claude:`
  block. Switch the live backend by setting this field; everything else in the workflow is shared.
- The `claude:` block configures the Claude Code backend: `command` (binary, default `claude`),
  `model` (default `claude-opus-4-8`), `effort` (`low`/`medium`/`high`/`xhigh`/`max`),
  `permission_mode` (default `bypassPermissions`), optional `env_file` sourced for credentials such
  as `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`, and `turn_timeout_ms` (default `3_600_000`).
  These are only used when `agent.backend: claude`.
- `agent.max_turns` caps how many back-to-back agent turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- The same Phoenix server can expose a small authenticated realtime project activity stream at
  `/activity/v1/events` and `/activity/v1/stream`; see
  [docs/activity_stream.md](docs/activity_stream.md).

### Restart and Resume Audit

Symphony keeps scheduler state in memory, but restart continuity is task-backed. On startup it treats
tracker tasks in configured active states as the durable source of truth, logs a restart/resume audit,
then redispatches eligible work into the preserved per-issue workspace.

Run the read-only audit manually from `elixir/`:

```bash
mise exec -- mix symphony.resume_audit
```

The report lists active task identifiers, states, expected workspace paths, whether local workspaces
exist, and the action Symphony will take, such as resuming a preserved workspace or dispatching an
active task into a workspace. Remote worker workspaces are listed with existence `unknown` because
the audit does not SSH into workers.

### Kaneo Multi-Project Routing

For Kaneo, `tracker.project_id` remains supported for legacy single-project runners. To monitor
several Kaneo projects from one Symphony process, configure `tracker.projects` instead:

```yaml
tracker:
  kind: kaneo
  endpoint: https://kaneo.example.com/api
  api_key: $KANEO_API_KEY
  active_states: [to-do, in-progress, in-review, rework]
  terminal_states: [done]
  projects:
    - id: kaneo-project-alpha
      slug: alpha
      repo_url: git@github.com:your-org/alpha.git
      repo_ref: main
      workflow_file: /opt/symphony/workflows/alpha.md
    - id: kaneo-project-beta
      slug: beta
      repo_url: git@github.com:your-org/beta.git
```

Symphony polls all configured projects and prefixes Kaneo task identifiers with the project key
derived from `slug`, `name`, or `id`, for example `ALPHA-KANEO-1`. That project-aware identifier is
used in run metadata and workspace paths, so tasks with the same Kaneo number in different projects
do not collide.

Workspace hooks receive per-task routing environment variables:

- `KANEO_PROJECT_ID`, `KANEO_PROJECT_NAME`, `KANEO_PROJECT_SLUG`, `KANEO_PROJECT_KEY`
- `KANEO_TASK_ID`, `KANEO_TASK_IDENTIFIER`
- `SOURCE_REPO_URL`, `SOURCE_REPO_REF`
- `SYMPHONY_WORKFLOW_FILE`

The default clone hook can therefore stay generic:

```sh
repo_url="${SOURCE_REPO_URL:?missing SOURCE_REPO_URL}"
repo_ref="${SOURCE_REPO_REF:-}"
git clone --depth 1 "$repo_url" .
if [ -n "$repo_ref" ]; then
  git fetch --depth 1 origin "$repo_ref"
  git checkout FETCH_HEAD
fi
```

If `workflow_file` is set for a project, that file supplies the Codex prompt template for tasks from
that project while the global `WORKFLOW.md` still owns runner configuration.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
