# Kimi-First OpenClaw Sentinel

This workspace includes a lightweight sentinel that checks Symphony/Kaneo state
and open GitHub PR queues with cheap local/API probes, asks Kimi K2.6 through
Nikita's local OpenClaw Fireworks/Firepass auth profile to classify the
snapshot, and only escalates to the main GPT-5.5 high agent when changed
actionable work is found.

## Why this path exists

OpenClaw cron `agentTurn` jobs can specify `payload.model`, but Fireworks models
currently run through the Codex app-server path there and can fall back to
`openai/gpt-5.5`. The reliable Kimi-first path is a direct read-only Fireworks
chat completion using the existing OpenClaw auth profile:

```sh
python3 scripts/openclaw_kimi_cron_sentinel.py \
  --dry-run \
  --state /tmp/openclaw-kimi-sentinel-test.json \
  --log /tmp/openclaw-kimi-sentinel-test.log
```

`scripts/openclaw_kimi_cron_sentinel.py` wraps that Kimi call, keeps durable
dedupe state, and uses `openclaw agent --model openai/gpt-5.5 --thinking high`
only when Kimi returns `actionable: true`.

## Run Manually

Dry-run against live Kaneo without waking GPT-5.5:

```sh
python3 scripts/openclaw_kimi_cron_sentinel.py --dry-run
```

Use a temporary state file for repeatability checks:

```sh
python3 scripts/openclaw_kimi_cron_sentinel.py \
  --dry-run \
  --state /tmp/openclaw-kimi-sentinel-test.json \
  --log /tmp/openclaw-kimi-sentinel-test.log
```

Run with escalation enabled:

```sh
python3 scripts/openclaw_kimi_cron_sentinel.py --escalate
```

The script loads `/Users/borodutch/.config/symphony/kaneo.env`, discovers
non-archived Kaneo projects through `/auth/organization/list` and
`/project?workspaceId=...`, then uses `/Users/borodutch/.config/symphony/WORKFLOW.md`
as routing fallback for repo URLs and refs. If a project is missing explicit
repo routing, the sentinel infers GitHub repos from task descriptions and PR
links. It reports open GitHub PR queues for those repos, links PRs back to Kaneo
task codes when present in the PR title, body, or branch, and writes state to
`state/kimi-cron-sentinel.json` by default. It pins
`OPENCLAW_STATE_DIR=/Users/borodutch/.openclaw` for auth lookup and escalation
subprocesses so cron, launchd, and nested agent shells resolve the same profiles.

Each open PR is classified deterministically before Kimi sees the snapshot:

- `mergeability`: `clean`, `behind-but-mergeable`, `conflicted`, `draft`, or
  GitHub's raw merge state when it is less specific.
- `checks`: `passing`, `pending`, `failing`, `mixed`, or `unknown`.
- `linkedTaskIdentifier`: Kaneo task matched by variants such as
  `VEY-KANEO-18` or `VEY-18`.
- `flags`: draft/conflicted/behind/failing/pending, human approval gated,
  task done but PR open, no linked active task, or stale.
- `recommendedAction`: merge candidate, update branch before merge, needs
  conflict fix, close as superseded or rework conflicts, fix checks, wait for
  checks, awaiting human approval, or investigate.

Asset/concept/style/review-batch PRs are intentionally classified as
`awaiting human approval` even when GitHub reports them as mergeable.

Noise suppression is signature-based: the signature includes candidate task
state, Symphony running/retry counts, PR updated timestamps, checks, mergeability,
flags, linked task state, and recommended action. Idle runs with no actionable
tasks, no actionable PRs, and no Symphony running/retry state skip Kimi and do
not wake GPT-5.5. Unchanged actionable snapshots are reminded only after
`--reminder-seconds`.

## Install Recurring Job

Run it from launchd, cron, systemd, or another local scheduler. A typical
recurring command is:

```sh
HOME=/Users/borodutch python3 /path/to/symphony/scripts/openclaw_kimi_cron_sentinel.py \
  --escalate \
  --gh-home /Users/borodutch
```

Use a cadence such as every 2-10 minutes. The durable signature state keeps
unchanged actionable findings quiet until the reminder interval expires.

For a one-off disable, remove or stop the scheduler entry that invokes the
script. The sentinel itself does not install persistent state beyond its JSON
state and JSONL log files.

## Tuning

- Kimi model: `--kimi-model fireworks/accounts/fireworks/routers/kimi-k2p6-turbo`
- Kimi runtime: direct Fireworks chat completions with the OpenClaw
  `provider=fireworks` auth profile; no Kimi classification runs through
  `agentTurn` or Codex.
- Escalation model: `--escalation-model openai/gpt-5.5`
- GitHub scan limits: `--max-prs 50`; use `--skip-prs` to suppress PR
  scanning for a one-off run.
- GitHub auth home: `--gh-home /Users/borodutch` or
  `SYMPHONY_SENTINEL_GH_HOME=/Users/borodutch` when cron cannot see the same
  `gh` login as an interactive shell.
- Dynamic project discovery is on by default; use `--skip-dynamic-projects`
  for a one-off workflow-only dry run.
- Reminder interval for unchanged findings: `--reminder-seconds 21600`
- Candidate statuses: `planned`, `selected`, `to-do`, `rework`,
  `in-review`

## Validation

Run the deterministic unit tests:

```sh
python3 scripts/openclaw_kimi_cron_sentinel_test.py
```

Run live read-only dry-run output without state writes:

```sh
HOME=/Users/borodutch python3 scripts/openclaw_kimi_cron_sentinel.py \
  --dry-run \
  --no-state-write \
  --state /tmp/openclaw-kimi-sentinel-test.json \
  --log /tmp/openclaw-kimi-sentinel-test.log \
  --gh-home /Users/borodutch
```

The sentinel does not mutate Kaneo, GitHub, branches, PRs, or QA state. It only
reads Kaneo/Symphony/GitHub state, dedupes, classifies with Kimi, and optionally
wakes GPT-5.5 high with a bounded summary only for Kimi-confirmed actionable
work.
