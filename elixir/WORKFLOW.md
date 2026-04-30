---
tracker:
  kind: kaneo
  endpoint: "https://kaneo.icefish-betta.ts.net/api"
  api_key: "$KANEO_API_KEY"
  project_id: "$KANEO_PROJECT_ID"
  active_states:
    - to-do
    - in-progress
    - in-review
    - rework
  terminal_states:
    - done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    repo_url="${SOURCE_REPO_URL:-https://github.com/backmeupplz/voicy}"
    repo_ref="${SOURCE_REPO_REF:-}"
    git clone --depth 1 "$repo_url" .
    if [ -n "$repo_ref" ]; then
      git fetch --depth 1 origin "$repo_ref"
      git checkout FETCH_HEAD
    fi

    if [ -x .symphony/bootstrap.sh ]; then
      ./.symphony/bootstrap.sh
    elif [ -x scripts/symphony-bootstrap.sh ]; then
      ./scripts/symphony-bootstrap.sh
    fi
  before_remove: |
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
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Kaneo task `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:
- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless it is needed for new changes.
{% endif %}

## Portfolio context

Nikita runs many projects across many repos. This Symphony runner still targets **one Kaneo project / one repo at a time** via environment:
- `KANEO_PROJECT_ID` selects the Kaneo project.
- `SOURCE_REPO_URL` selects the repository to clone.
- `SOURCE_REPO_REF` is optional when a non-default branch or ref should be the base.

Be fluent about the broader portfolio, but only modify the repository cloned for this run. If the Kaneo task clearly refers to a different repo than the cloned one, stop, leave a concise blocker note in the workpad, and do not make speculative changes.

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

For Telegram bots, assume OpenClaw can validate interactive behavior using the logged-in Telegram browser session on this Mac. If the repository/task also supports scripted bot validation and the required bot token is available in the environment (for example `TELEGRAM_TEST_BOT_TOKEN`), you may use it for automated checks; otherwise, leave crisp manual QA notes in Kaneo.

## Core operating rules

1. This is an unattended orchestration session. Never ask a human to do routine follow-up inside the run.
2. Only stop early for a true blocker: missing auth, missing required tool, missing required secret, or repo/task mismatch.
3. Final message must report completed actions and blockers only. Do not include generic “next steps for user”.
4. Work only in the cloned repository copy.
5. Use Kaneo via the injected `kaneo_api` tool for comments/status tracking when available.
6. Keep a single persistent Kaneo workpad comment headed `## Codex Workpad`.
7. Reproduce before changing code whenever there is a bug or concrete failing behavior.
8. Treat ticket-provided `Validation`, `Test Plan`, or `Testing` sections as mandatory.
9. If you discover follow-up work outside the current scope, create a separate Kaneo backlog (`planned`) task instead of silently expanding scope.

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
- If approved and merged, move the issue to `done`.

## Quality bar before `in-review`

Do not move a task to `in-review` unless all of the following are true:
- the workpad accurately reflects the completed work;
- acceptance criteria are fully met;
- required validation/test-plan items are completed;
- the latest commit has green validation for the task scope;
- branch is pushed and PR is linked on the Kaneo task;
- all actionable PR feedback has been addressed or explicitly answered.

## Manual QA handoff expectations

When a task needs browser/device/manual validation, make the handoff concrete. Include:
- exact environment to use (for example Telegram Web in Safari, Chrome, iOS simulator, Android emulator);
- the user path to exercise;
- the expected result;
- any screenshots, recordings, or comments needed for approval.

Keep issue text concise, specific, and reviewer-oriented.