---
tracker:
  kind: kaneo
  endpoint: "https://kaneo.icefish-betta.ts.net/api"
  api_key: "$KANEO_API_KEY"
  projects:
    - id: "o6t18forxgspr6lj6lc3chz1"
      slug: sym
      repo_url: "https://github.com/backmeupplz/symphony"
      repo_ref: "main"
      workflow_file: "/Users/borodutch/code/symphony/elixir/WORKFLOW.md"
    - id: "ewttjw85y3ycpjpsqwwm5qwi"
      slug: voi
      repo_url: "https://github.com/backmeupplz/voicy"
      repo_ref: "main"
      workflow_file: "/Users/borodutch/code/symphony/elixir/WORKFLOW.md"
    - id: "vda4cor2pugbu4rt95lmhmye"
      name: "Eggs"
      slug: egg
      repo_url: "https://github.com/BigWhaleLabs/eggs-backend"
      repo_ref: "main"
      workflow_file: "/Users/borodutch/code/symphony/elixir/WORKFLOW.md"
      repos:
        - key: backend
          name: "Eggs Backend"
          repo_url: "https://github.com/BigWhaleLabs/eggs-backend"
          repo_ref: "main"
          default: true
        - key: frontend
          name: "Eggs Frontend"
          repo_url: "https://github.com/BigWhaleLabs/eggs-frontend"
          repo_ref: "main"
        - key: backend-archive
          name: "Eggs Backend Archive"
          repo_url: "https://github.com/BigWhaleLabs/eggs-backend-archive"
          repo_ref: "main"
        - key: frontend-archive
          name: "Eggs Frontend Archive"
          repo_url: "https://github.com/BigWhaleLabs/eggs-frontend-archive"
          repo_ref: "main"
    - id: "ewi8212k2fhccay7h0yvh5hs"
      name: "Marketing"
      slug: mkt
      repo_url: "https://github.com/backmeupplz/marketing"
      repo_ref: "main"
      workflow_file: "/Users/borodutch/code/symphony/elixir/WORKFLOW.md"
      repos:
        - key: notes
          name: "Marketing Notes"
          repo_url: "https://github.com/backmeupplz/marketing"
          repo_ref: "main"
          default: true
        - key: profile
          name: "GitHub Profile"
          repo_url: "https://github.com/backmeupplz/backmeupplz"
          repo_ref: "main"
        - key: website
          name: "borodutch.com"
          repo_url: "https://github.com/backmeupplz/borodutch"
          repo_ref: "main"
        - key: stats
          name: "borodutch.com stats"
          repo_url: "https://github.com/backmeupplz/borodutch-stats"
          repo_ref: "master"
    - id: "luw130255z9zfh5vfwb3cpgh"
      name: "MyGround"
      slug: myg
      repo_url: "https://github.com/backmeupplz/myground"
      repo_ref: "master"
      workflow_file: "/Users/borodutch/code/symphony/elixir/WORKFLOW.md"
  assignee: "$KANEO_ASSIGNEE"
  active_states:
    - to-do
    - in-progress
    - rework
  terminal_states:
    - done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    clone_repo() {
      target="$1"
      repo_url="$2"
      repo_ref="${3:-}"
      git clone --depth 1 "$repo_url" "$target"
      if [ -n "$repo_ref" ]; then
        git -C "$target" fetch --depth 1 origin "$repo_ref"
        git -C "$target" checkout FETCH_HEAD
      fi
    }

    bootstrap_repo() {
      target="$1"
      if [ -f "$target/elixir/mise.toml" ]; then
        (cd "$target/elixir" && mise trust && mise install && mise exec -- mix deps.get)
      fi

      if [ -x "$target/.symphony/bootstrap.sh" ]; then
        (cd "$target" && ./.symphony/bootstrap.sh)
      elif [ -x "$target/scripts/symphony-bootstrap.sh" ]; then
        (cd "$target" && ./scripts/symphony-bootstrap.sh)
      fi
    }

    if [ -n "${SOURCE_REPOS_JSON:-}" ]; then
      repo_count=$(python3 -c 'import json, os; print(len(json.loads(os.environ["SOURCE_REPOS_JSON"])))')
    else
      repo_count=0
    fi

    if [ "$repo_count" -gt 1 ]; then
      mkdir -p repos
      python3 -c 'import json, os, re; print("\n".join("\t".join([re.sub(r"[^A-Za-z0-9._-]+", "-", (repo.get("key") or repo.get("name") or "repo")).strip("-") or "repo", repo.get("repo_url") or "", repo.get("repo_ref") or ""]) for repo in json.loads(os.environ["SOURCE_REPOS_JSON"])))' > .symphony-repos.tsv

      while IFS="$(printf '\t')" read -r repo_key repo_url repo_ref; do
        if [ -n "$repo_url" ]; then
          clone_repo "repos/$repo_key" "$repo_url" "$repo_ref"
          bootstrap_repo "repos/$repo_key"
        fi
      done < .symphony-repos.tsv

      {
        echo "# Selected repos"
        echo
        while IFS="$(printf '\t')" read -r repo_key repo_url repo_ref; do
          echo "- \`repos/$repo_key\` -> $repo_url ${repo_ref:+($repo_ref)}"
        done < .symphony-repos.tsv
      } > REPOS.md
    else
      repo_url="${SOURCE_REPO_URL:-https://github.com/backmeupplz/symphony}"
      repo_ref="${SOURCE_REPO_REF:-}"
      clone_repo . "$repo_url" "$repo_ref"
      bootstrap_repo .
    fi
  before_remove: |
    if [ -f elixir/mix.exs ]; then
      cd elixir && mise exec -- mix workspace.before_remove
      cd ..
    fi

    if [ -x .symphony/cleanup.sh ]; then
      ./.symphony/cleanup.sh
    elif [ -x scripts/symphony-cleanup.sh ]; then
      ./scripts/symphony-cleanup.sh
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Kaneo task `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:
- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless it is needed for new changes.
{% endif %}

## Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- URL: {{ issue.url }}

## Portfolio context

Nikita runs many projects across many repos. This Symphony runner can monitor a portfolio through
`tracker.projects` in `WORKFLOW.md`. In legacy single-project mode:
- `KANEO_PROJECT_ID` selects the Kaneo project.
- `SOURCE_REPO_KEY` names the configured repo inside a multi-repo project when one is selected.
- `SOURCE_REPO_URL` selects the repository to clone.
- `SOURCE_REPO_REF` is optional when a non-default branch or ref should be the base.

In multi-project mode, each configured Kaneo project supplies its repo routing. A project may define
multiple repos. Tasks can select one with `SOURCE_REPO_KEY=<key>` / `repo_key: <key>`, select several
with `SOURCE_REPO_KEYS=<key>,<key>` / `repo_keys: <key>,<key>`, or provide an explicit
`SOURCE_REPO_URL=<url>`. If no repo is specified, the runner infers repo keys from the task title and
description, then falls back to the project default. The runner injects `KANEO_PROJECT_ID`,
`SOURCE_REPO_KEY`, `SOURCE_REPO_URL`, `SOURCE_REPO_REF`, `SOURCE_REPOS_JSON`, and
`SYMPHONY_WORKFLOW_FILE` into workspace hooks for the specific task being executed.

Be fluent about the broader portfolio, but only modify the repository or repositories cloned for this run. If the Kaneo task clearly refers to a different repo than the cloned workspace, stop, leave a concise blocker note in the workpad, and do not make speculative changes.

## Kaneo board contract

Use this workflow model consistently for every project:
- Kaneo built-in backlog (`planned`) is the parking lot for ideas, design exploration, and not-yet-ready work.
- Active board columns are:
  1. `to-do`
  2. `in-progress`
  3. `in-review`
  4. `rework`
  5. `done`
- `done` is terminal.
- `planned`/backlog is **not** an active execution state for Symphony.

If a task is in backlog / `planned`, do not start it. Wait for OpenClaw or a human to move it to `to-do`.

## Lane model: design, coding, testing, QA

Treat work as one of these lanes:

1. **Design**
   - Human-in-the-loop.
   - OpenClaw coordinates design review, screenshots, feedback, and approval.
   - Design-only tasks should usually stay in Kaneo backlog until approved and translated into implementation-ready work.
   - Only execute a design task if it explicitly asks for repo-local design artifacts and has concrete acceptance criteria that can be completed inside the repo.

2. **Coding / implementation**
   - This is the primary Symphony lane.
   - Implement in the cloned repo, validate locally, push a branch, and open/update the PR.

3. **Testing / QA**
   - Codex owns repo-local automated validation: tests, typechecks, lint, builds, fixtures, scripted checks.
   - OpenClaw owns manual and interactive QA when browser login state, local apps, mobile simulators, Safari/Chrome sessions, Telegram Web, or device-specific validation are required.
   - When manual QA is needed, document exactly what needs to be verified so OpenClaw or Nikita can run that loop cleanly.

### Telegram-specific testing

For Telegram bots, prefer the repo-supported Telegram Web CDP path documented in
`elixir/docs/telegram_web_qa.md` and implemented by `scripts/telegram_web_qa.mjs`. OpenClaw should
use a dedicated logged-in Chrome QA profile launched with remote debugging, then run the helper to
send and verify a timestamped message to the target bot. Do not use Peekaboo, AppleScript JavaScript
execution, or Chrome's disabled "Allow JavaScript from Apple Events" path for Telegram Web QA.

If the repository/task also supports scripted bot validation and the required bot token is available
in the environment (for example `TELEGRAM_TEST_BOT_TOKEN`), you may use it for automated checks.
Otherwise, use the CDP helper for Telegram-side proof. If the helper cannot connect to a logged-in
Telegram Web profile, leave a crisp manual QA handoff note in Kaneo that includes the Chrome remote
debugging URL, target bot, exact message text, and expected verification.

## Core operating rules

1. This is an unattended orchestration session. Never ask a human to do routine follow-up inside the run.
2. Only stop early for a true blocker: missing auth, missing required tool, missing required secret, or repo/task mismatch.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only in the cloned repository copy.
5. Use Kaneo via the injected `kaneo_api` tool for comments/status tracking when available.
6. Keep a single persistent Kaneo workpad comment headed `## Codex Workpad`.
7. Reproduce before changing code whenever there is a bug or concrete failing behavior.
8. Treat ticket-provided `Validation`, `Test Plan`, or `Testing` sections as mandatory.
9. If you discover follow-up work outside the current scope, create a separate Kaneo backlog (`planned`) task instead of silently expanding scope.
10. If the repo includes `.codex/skills/land/SKILL.md`, open and follow `.codex/skills/land/SKILL.md` before making substantial changes.
11. Do not call `gh pr merge` directly.

## Status map

- `planned` / backlog -> not active; do not modify, do not start.
- `to-do` -> queued; immediately move to `in-progress` before active work begins.
- `in-progress` -> active implementation.
- `in-review` -> work is implemented and waiting on human review / approval / external QA.
- `rework` -> feedback or QA changes required; perform another implementation pass.
- `done` -> terminal; stop.

## Execution flow

### Step 0: route by state

1. Fetch the task and read its current state.
2. Route:
   - `planned` -> stop, wait for promotion to `to-do`.
   - `to-do` -> move to `in-progress`, then begin execution.
   - `in-progress` -> continue execution.
   - `in-review` -> do not code; poll for review feedback or approval.
   - `rework` -> perform a fresh implementation pass focused on feedback.
   - `done` -> stop.
3. If the task content and current state disagree, note the mismatch in the workpad and take the safest path.

### Step 1: maintain the workpad

Use exactly one persistent Kaneo comment with this structure:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan
- [ ] 1\. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria
- [ ] Criterion

### Validation
- [ ] targeted checks: `<command>`

### Testing Handoff
- Automated validation run:
  - [ ] `<command>` - result/evidence
- Manual QA for OpenClaw/humans:
  - [ ] Required or not required; if required, include environment, path to exercise, expected result, and evidence to attach.

### Notes
- timestamped notes

### Confusions
- only when something was genuinely unclear
````

Rules:
- Reuse the existing workpad if present.
- Update it before new implementation work.
- Keep plan, acceptance criteria, and validation current.
- Check items off as soon as they are actually complete.
- Record reproduction evidence, sync results, validation commands, PR links, and blockers there.
- Keep `### Testing Handoff` current before moving to `in-review`.
- Distinguish automated validation Symphony already ran from manual QA still needed from OpenClaw or humans.
- If no manual QA is needed, say `Manual QA: not required` and give the reason plus automated validation evidence.
- Suggest manual or integration checks only when they follow from the changed surface area and available context.
- If the right manual QA path is unknown, say what is unknown and ask OpenClaw or humans to choose the relevant QA path instead of inventing steps.

### Step 2: implementation loop

1. Confirm repo state (`branch`, `git status`, `HEAD`).
2. Sync with latest `origin/main` before substantial edits.
3. Implement against the plan.
4. Run the smallest meaningful proof after each milestone.
5. Re-run required validation before every push.
6. Push branch updates and keep the PR current.
7. Attach the PR URL to the Kaneo issue and ensure the PR has label `symphony`.
8. Resolve all actionable PR feedback before moving back to `in-review`.

### Step 3: review / QA loop

When the task is `in-review`:
- Do not continue coding unless review feedback arrives.
- Poll PR comments, review comments, and CI/check status.
- If changes are requested, move the issue to `rework` and address them.
- If approved and merged, confirm the merged PR head branch was deleted before moving the issue to `done`.
  When Symphony owns the merge, use `gh pr merge --squash --delete-branch` via the land skill.
  When OpenClaw or a human owns the merge, include branch deletion in the handoff checklist and verify
  the remote branch is gone; if cleanup is still needed, delete only the merged PR head ref with
  `gh api --method DELETE repos/{owner}/{repo}/git/refs/heads/<branch>`.
- Never delete default/protected branches or a branch with an open PR; treat GitHub 403/404/422 deletion
  responses as safe failures to document instead of widening the deletion target.
- After branch cleanup is verified or safely skipped, move the issue to `done`.

## Quality bar before `in-review`

Do not move a task to `in-review` unless all of the following are true:
- the workpad accurately reflects the completed work;
- acceptance criteria are fully met;
- required validation/test-plan items are completed;
- the latest commit has green validation for the task scope;
- branch is pushed and PR is linked on the Kaneo task;
- all actionable PR feedback has been addressed or explicitly answered.
- the workpad and PR description/comment contain a concise `Testing` or `Validation` handoff that separates:
  - automated checks Symphony ran, with command/result evidence;
  - manual QA still required, or an explicit `Manual QA: not required` with rationale.
  - bounded review guidance tied to the actual changed surface area, with unknowns called out.

## Manual QA handoff expectations

When a task needs browser/device/manual validation, make the handoff concrete. Include:
- exact environment to use (for example Telegram Web in Safari, Chrome, iOS simulator, Android emulator);
- the user path to exercise;
- the expected result;
- any screenshots, recordings, or comments needed for approval.
- for Telegram Web QA, whether the CDP helper was used, the Chrome remote debugging URL, target bot,
  message text, and the helper's JSON verification output or the blocker preventing it.

When manual QA is not needed, the handoff must still say so explicitly and list the automated
checks that are enough for review. The handoff should let OpenClaw or Nikita decide whether an
`in-review` task can move to `done` without rereading the whole branch.

Do not turn this into a broad QA script. Keep guidance lightweight, reviewer-oriented, and limited
to what Symphony can justify from the code changes and task context.

Keep issue text concise, specific, and reviewer-oriented.
