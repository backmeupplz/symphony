#!/usr/bin/env python3
"""Kimi-first lightweight Kaneo/Symphony sentinel for OpenClaw cron work."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_WORKFLOW = "/Users/borodutch/.config/symphony/WORKFLOW.md"
DEFAULT_ENV = "/Users/borodutch/.config/symphony/kaneo.env"
DEFAULT_STATE = "state/kimi-cron-sentinel.json"
DEFAULT_LOG = "state/kimi-cron-sentinel.log"
DEFAULT_OPENCLAW = "/opt/homebrew/bin/openclaw"
DEFAULT_OPENCLAW_STATE_DIR = "/Users/borodutch/.openclaw"
DEFAULT_FIREWORKS_BASE_URL = "https://api.fireworks.ai/inference/v1"
DEFAULT_KIMI_MODEL = "fireworks/accounts/fireworks/routers/kimi-k2p6-turbo"
DEFAULT_ESCALATION_MODEL = "openai/gpt-5.5"
DEFAULT_REMINDER_SECONDS = 6 * 60 * 60
ACTIONABLE_STATUSES = {"planned", "selected", "to-do", "rework", "in-review"}
ACTIVE_TASK_STATUSES = {"selected", "to-do", "in-progress", "rework", "in-review"}
TESTING_OPEN_PR_RECOVERY_STATUS = "in-review"
TESTING_OPEN_PR_RECOVERY_MARKER = "## Open PR Review Recovery"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat()


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'\"")
        if key and key not in os.environ:
            os.environ[key] = value


def parse_workflow_projects(path: Path) -> tuple[str, list[dict[str, Any]]]:
    if not path.exists():
        return "https://kaneo.icefish-betta.ts.net/api", []

    text = path.read_text(encoding="utf-8")
    endpoint_match = re.search(r'^\s*endpoint:\s*"?([^"\s]+)"?\s*$', text, re.M)
    endpoint = endpoint_match.group(1) if endpoint_match else "https://kaneo.icefish-betta.ts.net/api"
    projects: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    in_projects = False
    in_repos = False
    current_repo: dict[str, str] | None = None
    for line in text.splitlines():
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if re.match(r"^\s*projects:\s*$", line):
            in_projects = True
            continue
        if in_projects and indent <= 2 and re.match(r"^[a-zA-Z_]+:", stripped):
            break
        # Project start: 4-space indent, dash, id
        match = re.match(r'^\s{4}-\s+id:\s*"?([^"\s]+)"?\s*$', line)
        if match:
            if current_repo and current:
                current.setdefault("repos", []).append(current_repo)
                current_repo = None
            if current:
                projects.append(current)
            current = {"id": match.group(1)}
            in_repos = False
            current_repo = None
            continue
        if not current:
            continue
        # Project-level keys at 6-space indent
        for key in ("name", "slug", "repo_url", "repo_ref", "workflow_file"):
            match = re.match(rf'^\s{{6}}{key}:\s*"?([^"]+?)"?\s*$', line)
            if match:
                current[key] = match.group(1).strip()
                continue
        # repos array start at 6-space indent
        if re.match(r'^\s{6}repos:\s*$', line):
            in_repos = True
            continue
        if in_repos:
            # Repo item start at 8-space indent
            match = re.match(r'^\s{8}-\s+key:\s*"?([^"]+?)"?\s*$', line)
            if match:
                if current_repo and current:
                    current.setdefault("repos", []).append(current_repo)
                current_repo = {"key": match.group(1).strip()}
                continue
            if not current_repo:
                continue
            # Repo-level keys at 10-space indent
            for key in ("name", "repo_url", "repo_ref"):
                match = re.match(rf'^\s{{10}}{key}:\s*"?([^"]+?)"?\s*$', line)
                if match:
                    current_repo[key] = match.group(1).strip()
                    continue
            # Exit repos section when we see a 6-space line that's not a repo key
            if indent == 6 and not re.match(r'^\s{6}repos:', line):
                if current_repo and current:
                    current.setdefault("repos", []).append(current_repo)
                    current_repo = None
                in_repos = False
    # Flush remaining
    if current_repo and current:
        current.setdefault("repos", []).append(current_repo)
    if current:
        projects.append(current)
    return endpoint.rstrip("/"), projects


def fetch_json(url: str, *, api_key: str | None = None, timeout: int = 8) -> Any:
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
    return json.loads(data.decode("utf-8"))


def send_json(
    url: str,
    payload: dict[str, Any],
    *,
    method: str,
    api_key: str,
    timeout: int = 8,
) -> Any:
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
    if not data:
        return None
    return json.loads(data.decode("utf-8"))


def fetch_kaneo_json(
    endpoint: str,
    path: str,
    *,
    api_key: str,
    params: dict[str, Any] | None = None,
    timeout: int = 8,
) -> Any:
    query = ""
    if params:
        query = "?" + urllib.parse.urlencode({key: value for key, value in params.items() if value is not None})
    return fetch_json(f"{endpoint.rstrip('/')}{path}{query}", api_key=api_key, timeout=timeout)


def send_kaneo_json(
    endpoint: str,
    path: str,
    payload: dict[str, Any],
    *,
    method: str,
    api_key: str,
    timeout: int = 8,
) -> Any:
    return send_json(
        f"{endpoint.rstrip('/')}{path}",
        payload,
        method=method,
        api_key=api_key,
        timeout=timeout,
    )


def project_match_keys(project: dict[str, Any]) -> set[str]:
    keys: set[str] = set()
    for key in ("id", "slug", "name"):
        value = project.get(key)
        if value:
            keys.add(str(value).strip().lower())
    return keys


def extract_github_urls(text: str) -> list[str]:
    if not text:
        return []
    patterns = [
        r"https://github\.com/[^\s)>\]}\"']+",
        r"git@github\.com:[^\s)>\]}\"']+",
    ]
    urls: list[str] = []
    for pattern in patterns:
        urls.extend(re.findall(pattern, text))
    return list(dict.fromkeys(urls))


def project_repos_from_tasks(project: dict[str, Any]) -> list[dict[str, str]]:
    repos: list[dict[str, str]] = []
    seen: set[str] = set()
    tasks = project.get("tasks") if isinstance(project.get("tasks"), list) else []
    for task in tasks:
        if not isinstance(task, dict):
            continue
        text = "\n".join([str(task.get("title") or ""), str(task.get("description") or "")])
        for url in extract_github_urls(text):
            owner_repo = parse_github_repo(url)
            if not owner_repo or owner_repo in seen:
                continue
            seen.add(owner_repo)
            repos.append(
                {
                    "key": owner_repo.replace("/", "-").lower(),
                    "name": owner_repo,
                    "repo_url": f"https://github.com/{owner_repo}.git",
                }
            )
    return repos


def discover_kaneo_projects(endpoint: str, api_key: str) -> tuple[list[dict[str, Any]], list[str]]:
    projects: list[dict[str, Any]] = []
    errors: list[str] = []

    try:
        workspaces = fetch_kaneo_json(endpoint, "/auth/organization/list", api_key=api_key, timeout=10)
    except Exception as exc:  # noqa: BLE001 - report in sentinel probe output.
        return [], [f"organization discovery: {type(exc).__name__}: {exc}"]

    if not isinstance(workspaces, list):
        return [], ["organization discovery: expected list response"]

    seen_project_ids: set[str] = set()
    for workspace in workspaces:
        if not isinstance(workspace, dict):
            continue
        workspace_id = workspace.get("workspaceId") or workspace.get("id")
        if not workspace_id:
            continue
        try:
            workspace_projects = fetch_kaneo_json(
                endpoint,
                "/project",
                api_key=api_key,
                params={"workspaceId": workspace_id},
                timeout=10,
            )
        except Exception as exc:  # noqa: BLE001 - one workspace should not blind the sentinel.
            label = workspace.get("slug") or workspace.get("name") or workspace_id
            errors.append(f"{label}: {type(exc).__name__}: {exc}")
            continue
        if not isinstance(workspace_projects, list):
            errors.append(f"{workspace_id}: expected project list response")
            continue
        for project in workspace_projects:
            if not isinstance(project, dict) or project.get("archivedAt"):
                continue
            project_id = str(project.get("id") or "")
            if not project_id or project_id in seen_project_ids:
                continue
            seen_project_ids.add(project_id)
            repos = project_repos_from_tasks(project)
            projects.append(
                {
                    "id": project_id,
                    "workspaceId": str(workspace_id),
                    "name": project.get("name"),
                    "slug": project.get("slug"),
                    "repos": repos,
                    "repo_url": repos[0]["repo_url"] if len(repos) == 1 else None,
                    "repo_ref": None,
                    "workflow_file": None,
                    "discovered?": True,
                }
            )

    return projects, errors


def merge_project_sources(discovered: list[dict[str, Any]], configured: list[dict[str, Any]]) -> list[dict[str, Any]]:
    configured_by_key: dict[str, dict[str, Any]] = {}
    for project in configured:
        for key in project_match_keys(project):
            configured_by_key.setdefault(key, project)

    merged: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    for project in discovered:
        match = next((configured_by_key[key] for key in project_match_keys(project) if key in configured_by_key), None)
        item = dict(project)
        if match:
            for key in ("repo_url", "repo_ref", "workflow_file"):
                if match.get(key):
                    item[key] = match[key]
            if match.get("repos"):
                item["repos"] = match["repos"]
        merged.append(item)
        if item.get("id"):
            seen_ids.add(str(item["id"]))

    for project in configured:
        project_id = str(project.get("id") or "")
        if project_id and project_id in seen_ids:
            continue
        merged.append(project)

    return merged


def fetch_optional_json(url: str, *, timeout: int = 4) -> tuple[Any | None, str | None]:
    try:
        return fetch_json(url, timeout=timeout), None
    except Exception as exc:  # noqa: BLE001 - report and continue on sentinel probes.
        return None, f"{type(exc).__name__}: {exc}"


def openclaw_env(state_dir: str) -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("OPENCLAW_STATE_DIR", state_dir)
    return env


def load_fireworks_api_key(state_dir: str) -> tuple[str | None, str]:
    if os.environ.get("FIREWORKS_API_KEY"):
        return os.environ["FIREWORKS_API_KEY"], "env:FIREWORKS_API_KEY"
    auth_path = Path(state_dir) / "agents/main/agent/auth-profiles.json"
    try:
        data = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - auth lookup is reported, not fatal to the whole sentinel.
        return None, f"{auth_path}: {type(exc).__name__}: {exc}"
    profiles = data.get("profiles") if isinstance(data, dict) else None
    if not isinstance(profiles, dict):
        return None, f"{auth_path}: missing profiles map"
    for profile_id, profile in profiles.items():
        if isinstance(profile, dict) and profile.get("provider") == "fireworks" and profile.get("key"):
            return str(profile["key"]), f"{auth_path}:profile:{profile_id}:provider:fireworks"
    return None, f"{auth_path}: no fireworks profile with key"


def fireworks_model_id(model: str) -> str:
    for prefix in ("fireworks/", "fireworks-ai/"):
        if model.startswith(prefix):
            return model[len(prefix) :]
    return model


def valid_classification(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and isinstance(value.get("actionable"), bool)
        and isinstance(value.get("summary"), str)
        and isinstance(value.get("decision_points"), list)
    )


def parse_classification_from_text(text: str) -> dict[str, Any] | None:
    try:
        value = json.loads(text)
        if valid_classification(value):
            return value
    except json.JSONDecodeError:
        pass
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if valid_classification(value):
            return value
    return None


def task_identifier(project: dict[str, Any], task: dict[str, Any]) -> str:
    slug = str(project.get("slug") or project.get("name") or "KANEO").upper()
    return f"{slug}-KANEO-{task.get('number')}"


def latest_activity_marker(endpoint: str, api_key: str, task_id: str) -> str | None:
    try:
        activities = fetch_json(f"{endpoint}/activity/{task_id}", api_key=api_key, timeout=6)
    except Exception:
        return None
    markers = [
        str(item.get("updatedAt") or item.get("createdAt") or "")
        for item in activities
        if isinstance(item, dict)
    ]
    return max(markers) if markers else None


# ── GitHub PR helpers ──────────────────────────────────────────────────────────


def parse_github_repo(url: str) -> str | None:
    """Parse owner/repo from a GitHub URL, return None for non-GitHub or local paths."""
    if not url:
        return None
    value = url.strip().rstrip(".,;")
    match = re.match(r"https://github\.com/([^/\s]+)/([^/\s?#]+)", value)
    if not match:
        match = re.match(r"git@github\.com:([^/\s]+)/([^/\s?#]+)", value)
    if match:
        repo = match.group(2).removesuffix(".git")
        return f"{match.group(1)}/{repo}"
    return None


def extract_github_repos(projects: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Extract unique GitHub owner/repo pairs from workflow project config."""
    repos: list[dict[str, str]] = []
    seen: set[str] = set()
    for project in projects:
        # Top-level repo_url
        owner_repo = parse_github_repo(project.get("repo_url", ""))
        if owner_repo and owner_repo not in seen:
            seen.add(owner_repo)
            repos.append(
                {
                    "owner": owner_repo.split("/")[0],
                    "repo": owner_repo.split("/")[1],
                    "projectSlug": project.get("slug") or project.get("name") or "unknown",
                }
            )
        # Nested repos array (for multi-repo projects like Eggs, Marketing)
        for repo in project.get("repos", []):
            if not isinstance(repo, dict):
                continue
            owner_repo = parse_github_repo(repo.get("repo_url", ""))
            if owner_repo and owner_repo not in seen:
                seen.add(owner_repo)
                repos.append(
                    {
                        "owner": owner_repo.split("/")[0],
                        "repo": owner_repo.split("/")[1],
                        "projectSlug": project.get("slug") or project.get("name") or "unknown",
                    }
                )
    return repos


def fetch_prs_for_repo(
    owner: str,
    repo: str,
    limit: int = 20,
    *,
    gh_home: str | None = None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Fetch open PRs for a GitHub repo using gh CLI."""
    env = os.environ.copy()
    if gh_home:
        env["HOME"] = gh_home
    try:
        proc = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "--repo",
                f"{owner}/{repo}",
                "--state",
                "open",
                "--json",
                "number,title,body,url,updatedAt,createdAt,author,headRefName,baseRefName,reviewDecision,isDraft,mergeable,mergeStateStatus,statusCheckRollup",
                "--limit",
                str(limit),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
            env=env,
        )
        if proc.returncode != 0:
            return [], f"gh error: {proc.stderr.strip()[:500]}"
        data = json.loads(proc.stdout)
        if not isinstance(data, list):
            return [], f"unexpected gh output: {proc.stdout[:500]}"
        return data, None
    except Exception as exc:  # noqa: BLE001 - report and continue on sentinel probes.
        return [], f"{type(exc).__name__}: {exc}"


def summarize_checks(rollup: list[dict[str, Any]]) -> str:
    """Summarize check run status into a single string."""
    if not rollup:
        return "unknown"
    conclusions: list[str] = []
    for check in rollup:
        if not isinstance(check, dict):
            continue
        status = check.get("status")
        conclusion = check.get("conclusion")
        if status == "COMPLETED":
            conclusions.append(conclusion or "unknown")
        elif status == "IN_PROGRESS":
            conclusions.append("PENDING")
        else:
            conclusions.append("PENDING")
    if any(item in conclusions for item in ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED")):
        return "failing"
    if "PENDING" in conclusions:
        return "pending"
    if all(c in {"SUCCESS", "NEUTRAL", "SKIPPED"} for c in conclusions):
        return "passing"
    return "mixed"


def pr_age_days(updated_at: Any) -> int | None:
    if not updated_at:
        return None
    value = str(updated_at)
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            parsed = dt.datetime.strptime(value, fmt)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return int((utc_now() - parsed).total_seconds() // 86400)
        except ValueError:
            continue
    return None


def human_approval_gated(pr: dict[str, Any], linked_task_title: str | None) -> bool:
    text = " ".join(
        [
            str(pr.get("title") or ""),
            str(pr.get("body") or ""),
            str(pr.get("headRefName") or ""),
            str(linked_task_title or ""),
        ]
    ).lower()
    markers = ("asset", "assets", "concept", "visual", "style-pass", "style pass", "review batch", "human review")
    return any(marker in text for marker in markers)


def classify_pr(
    pr: dict[str, Any],
    *,
    linked_task_status: str | None = None,
    linked_task_title: str | None = None,
) -> dict[str, Any]:
    """Classify a PR for actionable reporting."""
    mergeable = pr.get("mergeable", "UNKNOWN")
    merge_state = pr.get("mergeStateStatus", "UNKNOWN")
    checks = summarize_checks(pr.get("statusCheckRollup", []))
    is_draft = pr.get("isDraft", False)
    review_decision = pr.get("reviewDecision", "")
    flags: list[str] = []
    if is_draft:
        mergeability = "draft"
        flags.append("draft")
    elif mergeable == "CONFLICTING" or merge_state == "DIRTY":
        mergeability = "conflicted"
        flags.append("conflicted")
    elif mergeable == "MERGEABLE" and merge_state == "BEHIND":
        mergeability = "behind-but-mergeable"
        flags.append("behind-but-mergeable")
    elif mergeable == "MERGEABLE":
        mergeability = "clean"
    else:
        mergeability = str(merge_state or mergeable or "UNKNOWN").lower()
    if checks == "failing":
        flags.append("failing-checks")
    elif checks == "pending":
        flags.append("pending-checks")
    if review_decision == "CHANGES_REQUESTED":
        flags.append("changes-requested")
    if human_approval_gated(pr, linked_task_title):
        flags.append("human-approval-gated")
    if linked_task_status == "done":
        flags.append("task-done-pr-open")
    elif linked_task_status == "testing":
        flags.append("testing-task-pr-open")
    elif linked_task_status not in ACTIVE_TASK_STATUSES:
        flags.append("no-linked-active-task")
    age_days = pr_age_days(pr.get("updatedAt"))
    if age_days is not None and age_days >= 7:
        flags.append("stale")
    if is_draft:
        action = "await draft readiness"
    elif "human-approval-gated" in flags:
        action = "awaiting human approval"
    elif "testing-task-pr-open" in flags:
        action = "testing open-pr recovery"
    elif "conflicted" in flags and "task-done-pr-open" in flags:
        action = "close as superseded or rework conflicts"
    elif "conflicted" in flags:
        action = "needs rebase/conflict fix"
    elif checks == "failing":
        action = "fix failing checks"
    elif checks == "pending":
        action = "wait for checks"
    elif review_decision == "CHANGES_REQUESTED":
        action = "needs rework"
    elif "task-done-pr-open" in flags:
        action = "investigate done task with open PR"
    elif "no-linked-active-task" in flags:
        action = "investigate missing active task"
    elif "behind-but-mergeable" in flags:
        action = "update branch before merge"
    elif mergeability == "clean" and checks in {"passing", "unknown"} and review_decision != "REVIEW_REQUIRED":
        action = "merge candidate"
    elif review_decision == "REVIEW_REQUIRED":
        action = "awaiting review"
    else:
        action = "investigate"

    return {
        "mergeable": mergeable,
        "mergeability": mergeability,
        "checks": checks,
        "isDraft": "true" if is_draft else "false",
        "reviewDecision": review_decision,
        "action": action,
        "recommendedAction": action,
        "flags": flags,
        "ageDays": age_days,
    }


def extract_task_refs(text: str) -> list[str]:
    """Extract task identifier references like VEY-KANEO-23 or VEY-23 from text."""
    return re.findall(r"[A-Z]{2,6}(?:-KANEO)?-\d+", text.upper())


def collect_github_prs(
    projects: list[dict[str, Any]],
    all_tasks_map: dict[str, dict[str, Any]],
    max_prs: int = 50,
    *,
    gh_home: str | None = None,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Collect open PRs from all GitHub repos in the workflow."""
    repos = extract_github_repos(projects)
    prs: list[dict[str, Any]] = []
    errors: list[str] = []

    for repo_info in repos:
        owner = repo_info["owner"]
        repo = repo_info["repo"]
        repo_prs, error = fetch_prs_for_repo(owner, repo, limit=20, gh_home=gh_home)
        if error:
            errors.append(f"{owner}/{repo}: {error}")
            continue

        for pr in repo_prs:
            # Extract task references from title and branch
            task_refs = extract_task_refs(pr.get("title", ""))
            task_refs.extend(extract_task_refs(pr.get("body", "")))
            task_refs.extend(extract_task_refs(pr.get("headRefName", "")))
            task_refs = list(dict.fromkeys(task_refs))  # dedupe preserve order

            # Cross-reference with all Kaneo tasks (not just actionable ones)
            linked_task_status: str | None = None
            linked_task_title: str | None = None
            linked_task_identifier: str | None = None
            for ref in task_refs:
                if ref in all_tasks_map:
                    linked_task = all_tasks_map[ref]
                    linked_task_status = str(linked_task.get("status") or "")
                    linked_task_title = str(linked_task.get("title") or "")
                    linked_task_identifier = str(linked_task.get("identifier") or ref)
                    break
            pr_class = classify_pr(
                pr,
                linked_task_status=linked_task_status,
                linked_task_title=linked_task_title,
            )

            # Flag if task is done but PR is still open
            task_done_pr_open = linked_task_status == "done" if linked_task_status else False

            prs.append(
                {
                    "repo": f"{owner}/{repo}",
                    "projectSlug": repo_info["projectSlug"],
                    "number": pr.get("number"),
                    "title": pr.get("title"),
                    "url": pr.get("url"),
                    "author": pr.get("author", {}).get("login") if isinstance(pr.get("author"), dict) else None,
                    "headRef": pr.get("headRefName"),
                    "baseRef": pr.get("baseRefName"),
                    "updatedAt": pr.get("updatedAt"),
                    "isDraft": pr_class["isDraft"] == "true",
                    "mergeable": pr_class["mergeable"],
                    "mergeability": pr_class["mergeability"],
                    "mergeState": pr.get("mergeStateStatus", "UNKNOWN"),
                    "checks": pr_class["checks"],
                    "reviewDecision": pr_class["reviewDecision"],
                    "action": pr_class["action"],
                    "recommendedAction": pr_class["recommendedAction"],
                    "flags": pr_class["flags"],
                    "ageDays": pr_class["ageDays"],
                    "taskRefs": task_refs,
                    "linkedTaskIdentifier": linked_task_identifier,
                    "linkedTaskTitle": linked_task_title,
                    "linkedTaskStatus": linked_task_status,
                    "taskDonePrOpen": task_done_pr_open,
                }
            )
            if len(prs) >= max_prs:
                break
        if len(prs) >= max_prs:
            break

    return prs, errors


def testing_open_pr_recovery_candidates(
    prs: list[dict[str, Any]],
    all_tasks_map: dict[str, dict[str, Any]],
    existing_candidates: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Create visible task candidates for open PRs linked to tasks currently in testing."""
    existing_task_ids = {str(item.get("taskId") or "") for item in existing_candidates}
    recovered_task_ids: set[str] = set()
    recoveries: list[dict[str, Any]] = []

    for pr in prs:
        if pr.get("linkedTaskStatus") != "testing":
            continue
        linked_identifier = str(pr.get("linkedTaskIdentifier") or "")
        if not linked_identifier:
            continue
        task = all_tasks_map.get(linked_identifier.upper())
        if not task:
            continue
        task_id = str(task.get("taskId") or "")
        if not task_id or task_id in existing_task_ids or task_id in recovered_task_ids:
            continue
        recovered_task_ids.add(task_id)
        recoveries.append(
            {
                "project": task.get("project"),
                "projectSlug": task.get("projectSlug"),
                "projectId": task.get("projectId"),
                "taskId": task_id,
                "identifier": task.get("identifier") or linked_identifier,
                "status": TESTING_OPEN_PR_RECOVERY_STATUS,
                "originalStatus": "testing",
                "priority": None,
                "updatedAt": task.get("updatedAt"),
                "activityMarker": None,
                "title": task.get("title"),
                "descriptionPreview": (
                    f"Testing open-PR recovery for {pr.get('repo')}#{pr.get('number')}: {pr.get('title')}"
                )[:360],
                "recoveryReason": "testing-open-pr",
                "recoveryPr": {
                    "repo": pr.get("repo"),
                    "number": pr.get("number"),
                    "title": pr.get("title"),
                    "url": pr.get("url"),
                    "headRef": pr.get("headRef"),
                    "action": pr.get("recommendedAction"),
                    "checks": pr.get("checks"),
                    "mergeability": pr.get("mergeability"),
                },
            }
        )

    return recoveries


def recovery_note_exists(endpoint: str, api_key: str, task_id: str, pr_url: str | None) -> bool:
    try:
        activities = fetch_kaneo_json(endpoint, f"/activity/{urllib.parse.quote(task_id)}", api_key=api_key, timeout=8)
    except Exception:
        return False
    if not isinstance(activities, list):
        return False
    for activity in activities:
        if not isinstance(activity, dict):
            continue
        content = str(activity.get("content") or "")
        if TESTING_OPEN_PR_RECOVERY_MARKER in content and (not pr_url or pr_url in content):
            return True
    return False


def build_recovery_note(recovery: dict[str, Any]) -> str:
    pr = recovery.get("recoveryPr") if isinstance(recovery.get("recoveryPr"), dict) else {}
    pr_label = f"{pr.get('repo')}#{pr.get('number')}"
    pr_url = str(pr.get("url") or "")
    return "\n".join(
        [
            TESTING_OPEN_PR_RECOVERY_MARKER,
            "",
            (
                f"Testing open-PR recovery: moved `{recovery.get('identifier')}` from `testing` "
                f"to `{TESTING_OPEN_PR_RECOVERY_STATUS}` because same-ticket PR {pr_label} is still open."
            ),
            "",
            f"Open PR: {pr_url or pr_label}",
            f"Current PR action: {pr.get('action')}; checks={pr.get('checks')}; mergeability={pr.get('mergeability')}",
            "",
            (
                "Reviewer handoff: finish review/merge/branch cleanup for this PR, then return the task "
                "to `testing` for bounded Kimi QA once the merged work is live-ready."
            ),
            "",
            "Duplicate guard: this recovery note is posted once per PR URL; reuse the existing recovery worker.",
        ]
    )


def reconcile_testing_open_pr_recoveries(
    endpoint: str,
    api_key: str,
    recoveries: list[dict[str, Any]],
    *,
    dry_run: bool,
    mutate: bool,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    if dry_run or not mutate:
        for recovery in recoveries:
            results.append(
                {
                    "taskId": recovery.get("taskId"),
                    "identifier": recovery.get("identifier"),
                    "status": "skipped",
                    "reason": "dry-run" if dry_run else "mutations-disabled",
                }
            )
        return results

    for recovery in recoveries:
        task_id = str(recovery.get("taskId") or "")
        pr = recovery.get("recoveryPr") if isinstance(recovery.get("recoveryPr"), dict) else {}
        pr_url = str(pr.get("url") or "")
        result = {
            "taskId": task_id,
            "identifier": recovery.get("identifier"),
            "status": "pending",
            "prUrl": pr_url,
        }
        if not task_id:
            result.update({"status": "error", "error": "missing taskId"})
            results.append(result)
            continue
        try:
            send_kaneo_json(
                endpoint,
                f"/task/status/{urllib.parse.quote(task_id)}",
                {"status": TESTING_OPEN_PR_RECOVERY_STATUS},
                method="PUT",
                api_key=api_key,
                timeout=10,
            )
            result["statusUpdatedTo"] = TESTING_OPEN_PR_RECOVERY_STATUS
        except Exception as exc:  # noqa: BLE001 - keep remaining recoveries moving and report.
            result.update({"status": "error", "error": f"status update: {type(exc).__name__}: {exc}"})
            results.append(result)
            continue
        try:
            if recovery_note_exists(endpoint, api_key, task_id, pr_url):
                result["note"] = "already-present"
            else:
                send_kaneo_json(
                    endpoint,
                    "/activity/comment",
                    {"taskId": task_id, "comment": build_recovery_note(recovery)},
                    method="POST",
                    api_key=api_key,
                    timeout=10,
                )
                result["note"] = "created"
            result["status"] = "ok"
        except Exception as exc:  # noqa: BLE001 - status is visible even if the note fails.
            result.update({"status": "partial", "error": f"note: {type(exc).__name__}: {exc}"})
        results.append(result)
    return results


# ── Existing sentinel helpers ────────────────────────────────────────────────


def collect_candidates(
    endpoint: str,
    projects: list[dict[str, Any]],
    *,
    api_key: str,
    max_candidates: int,
) -> tuple[list[dict[str, Any]], list[str], dict[str, dict[str, Any]]]:
    candidates: list[dict[str, Any]] = []
    errors: list[str] = []
    all_tasks_map: dict[str, dict[str, Any]] = {}  # identifier variants -> task record
    for project in projects:
        project_id = project["id"]
        try:
            data = fetch_json(f"{endpoint}/project/{project_id}", api_key=api_key, timeout=10)
        except Exception as exc:  # noqa: BLE001 - one project should not blind the whole sentinel.
            label = project.get("slug") or project.get("name") or project_id
            errors.append(f"{label}: {type(exc).__name__}: {exc}")
            continue
        merged_project = {
            "id": project_id,
            "name": data.get("name") or project.get("name") or project.get("slug") or project_id,
            "slug": data.get("slug") or project.get("slug") or project.get("name") or project_id,
        }
        for task in data.get("tasks", []):
            status = str(task.get("status") or "")
            ident = task_identifier(merged_project, task)
            task_id = str(task.get("id") or "")
            task_record = {
                "identifier": ident,
                "project": merged_project["name"],
                "projectSlug": merged_project["slug"],
                "projectId": project_id,
                "taskId": task_id,
                "number": task.get("number"),
                "status": status,
                "title": task.get("title"),
                "updatedAt": task.get("updatedAt"),
            }
            all_tasks_map[ident.upper()] = task_record
            if task.get("number") is not None:
                all_tasks_map[f"{str(merged_project['slug']).upper()}-{task.get('number')}"] = task_record
            if status not in ACTIONABLE_STATUSES:
                continue
            description = str(task.get("description") or "")
            candidates.append(
                {
                    "project": merged_project["name"],
                    "projectSlug": merged_project["slug"],
                    "projectId": project_id,
                    "taskId": task_id,
                    "identifier": ident,
                    "status": status,
                    "priority": task.get("priority"),
                    "updatedAt": task.get("updatedAt"),
                    "activityMarker": latest_activity_marker(endpoint, api_key, task_id) if task_id else None,
                    "title": task.get("title"),
                    "descriptionPreview": " ".join(description.split())[:360],
                }
            )
            if len(candidates) >= max_candidates:
                return candidates, errors, all_tasks_map
    return candidates, errors, all_tasks_map


def signature_for(
    candidates: list[dict[str, Any]],
    probe: dict[str, Any],
    prs: list[dict[str, Any]],
) -> tuple[str, list[dict[str, Any]], list[dict[str, Any]]]:
    normalized_candidates = []
    for item in candidates:
        normalized_candidates.append(
            {
                "taskId": item.get("taskId"),
                "status": item.get("status"),
                "originalStatus": item.get("originalStatus"),
                "recoveryReason": item.get("recoveryReason"),
                "recoveryPr": item.get("recoveryPr"),
                "updatedAt": item.get("updatedAt"),
                "activityMarker": item.get("activityMarker"),
                "title": item.get("title"),
            }
        )
    normalized_candidates.sort(key=lambda item: str(item.get("taskId")))
    normalized_prs = []
    for pr in prs:
        normalized_prs.append(
            {
                "repo": pr.get("repo"),
                "number": pr.get("number"),
                "updatedAt": pr.get("updatedAt"),
                "checks": pr.get("checks"),
                "mergeable": pr.get("mergeable"),
                "mergeability": pr.get("mergeability"),
                "mergeState": pr.get("mergeState"),
                "action": pr.get("action"),
                "recommendedAction": pr.get("recommendedAction"),
                "flags": pr.get("flags"),
                "isDraft": pr.get("isDraft"),
                "taskDonePrOpen": pr.get("taskDonePrOpen"),
            }
        )
    normalized_prs.sort(key=lambda pr: f"{pr.get('repo')}#{pr.get('number')}")
    payload = {
        "candidates": normalized_candidates,
        "prs": normalized_prs,
        "symphonyRunning": probe.get("runningCount"),
        "symphonyRetrying": probe.get("retryingCount"),
        "symphonyError": probe.get("error"),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest(), normalized_candidates, normalized_prs


def summarize_symphony_state(state: Any | None, error: str | None) -> dict[str, Any]:
    if not isinstance(state, dict):
        return {"ok": False, "error": error or "unavailable"}
    running = state.get("running")
    retrying = state.get("retrying")
    return {
        "ok": True,
        "runningCount": len(running) if isinstance(running, list) else 0,
        "retryingCount": len(retrying) if isinstance(retrying, list) else 0,
    }


def run_kimi(
    model: str,
    candidates: list[dict[str, Any]],
    probe: dict[str, Any],
    prs: list[dict[str, Any]],
    *,
    fireworks_base_url: str,
    state_dir: str,
) -> dict[str, Any]:
    compact_candidates = [
        {
            "identifier": item["identifier"],
            "status": item["status"],
            "title": item["title"],
            "originalStatus": item.get("originalStatus"),
            "recoveryReason": item.get("recoveryReason"),
            "recoveryPr": item.get("recoveryPr"),
        }
        for item in candidates
    ]
    compact_prs = [
        {
            "repo": pr["repo"],
            "number": pr["number"],
            "title": pr["title"],
            "action": pr["action"],
            "recommendedAction": pr["recommendedAction"],
            "checks": pr["checks"],
            "mergeable": pr["mergeable"],
            "mergeability": pr["mergeability"],
            "mergeState": pr["mergeState"],
            "flags": pr["flags"],
            "linkedTaskIdentifier": pr["linkedTaskIdentifier"],
            "taskDonePrOpen": pr["taskDonePrOpen"],
        }
        for pr in prs
    ]
    prompt = textwrap.dedent(
        f"""
        Classify this OpenClaw sentinel snapshot. Return exactly one minified JSON object
        with keys: actionable (boolean), summary (string under 160 chars),
        decision_points (array of short strings). No markdown.
        Actionable means at least one selected/to-do/rework/in-review task may need
        main-model judgment, or at least one open PR needs review/merge/conflict-fix/close
        decision. Planned tasks are decision points only. Draft PRs and awaiting-checks
        PRs are not actionable unless they are stale or conflicted. Do not infer a PR
        is conflicted unless its mergeability value is exactly "conflicted"; use the
        provided recommendedAction fields as the primary PR triage signal.
        Treat candidates with recoveryReason="testing-open-pr" as active review/merge
        recovery work, not as a normal testing/QA handoff.

        {json.dumps({"symphony": probe, "tasks": compact_candidates, "prs": compact_prs}, ensure_ascii=True)}
        """
    ).strip()
    runtime = "direct-fireworks-chat-completions"
    provider = "fireworks"
    api_key, auth_source = load_fireworks_api_key(state_dir)
    if not api_key:
        return {
            "ok": False,
            "model": model,
            "provider": provider,
            "runtime": runtime,
            "authSource": auth_source,
            "stderr": "Fireworks API key not found in environment or OpenClaw auth profiles.",
            "text": "",
            "classification": {
                "actionable": bool(candidates) or bool(prs),
                "summary": "Kimi classification could not authenticate; escalate only because the deterministic snapshot changed.",
                "decision_points": [],
            },
        }
    body = {
        "model": fireworks_model_id(model),
        "messages": [
            {
                "role": "system",
                "content": "You are a strict JSON API. Output only one minified JSON object and no markdown.",
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "max_tokens": 2048,
        "response_format": {"type": "json_object"},
    }
    request = urllib.request.Request(
        fireworks_base_url.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            raw = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        error_text = exc.read().decode("utf-8", errors="replace")[:1000]
        return {
            "ok": False,
            "model": model,
            "provider": provider,
            "runtime": runtime,
            "authSource": auth_source,
            "stderr": f"Fireworks HTTP {exc.code}: {error_text}",
            "text": "",
            "classification": {
                "actionable": bool(candidates) or bool(prs),
                "summary": "Kimi classification failed; escalate only because the deterministic snapshot changed.",
                "decision_points": [],
            },
        }
    except Exception as exc:  # noqa: BLE001 - report and continue on sentinel classification failures.
        return {
            "ok": False,
            "model": model,
            "provider": provider,
            "runtime": runtime,
            "authSource": auth_source,
            "stderr": f"{type(exc).__name__}: {exc}",
            "text": "",
            "classification": {
                "actionable": bool(candidates) or bool(prs),
                "summary": "Kimi classification failed; escalate only because the deterministic snapshot changed.",
                "decision_points": [],
            },
        }
    choice = (raw.get("choices") or [{}])[0] if isinstance(raw, dict) else {}
    message = choice.get("message") if isinstance(choice, dict) else {}
    text = str((message or {}).get("content") or "").strip()
    classification = parse_classification_from_text(text)
    classification_valid = classification is not None
    if classification is None:
        classification = {
            "actionable": bool(candidates) or bool(prs),
            "summary": f"Kimi returned invalid classifier JSON: {text[:720]}",
            "decision_points": [],
        }
    return {
        "ok": bool(text) and classification_valid,
        "model": model,
        "provider": provider,
        "runtime": runtime,
        "authSource": auth_source,
        "finishReason": choice.get("finish_reason") if isinstance(choice, dict) else None,
        "stderr": "" if text else "Fireworks returned no message content.",
        "text": text,
        "classification": classification,
    }


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def append_log(path: Path, event: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def should_escalate(state: dict[str, Any], signature: str, *, reminder_seconds: int, force: bool) -> tuple[bool, str]:
    if force:
        return True, "forced"
    previous = state.get("signatures", {}).get(signature)
    if not previous:
        return True, "changed"
    last = previous.get("lastEscalatedAt") or previous.get("lastClassifiedAt") or previous.get("lastDryRunAt")
    if not last:
        return True, "changed"
    try:
        last_dt = dt.datetime.fromisoformat(str(last))
    except ValueError:
        return True, "changed"
    age = (utc_now() - last_dt).total_seconds()
    if age >= reminder_seconds:
        return True, "reminder"
    return False, "unchanged"


def build_wake_message(
    candidates: list[dict[str, Any]],
    probe: dict[str, Any],
    prs: list[dict[str, Any]],
    kimi: dict[str, Any],
    reason: str,
) -> str:
    lines = [
        "Kimi-first OpenClaw sentinel found changed actionable Kaneo/Symphony work.",
        "",
        f"Escalation reason: {reason}",
        f"Kimi model: {kimi.get('model')}",
        f"Kimi result: {'ok' if kimi.get('ok') else 'failed'}",
    ]
    classification = kimi.get("classification")
    if isinstance(classification, dict):
        summary = str(classification.get("summary") or "").strip()
        if summary:
            lines.extend(["", f"Kimi summary: {summary[:1200]}"])
        decision_points = classification.get("decision_points")
        if isinstance(decision_points, list) and decision_points:
            lines.append("")
            lines.append("Decision points:")
            for point in decision_points[:8]:
                lines.append(f"- {str(point)[:240]}")
    elif kimi.get("text"):
        lines.extend(["", f"Kimi output: {str(kimi.get('text'))[:1200]}"])
    if not kimi.get("ok") and kimi.get("stderr"):
        lines.extend(["", f"Kimi error: {kimi.get('stderr')}"])
    lines.extend(["", "Symphony probe:", f"- {json.dumps(probe, sort_keys=True)}", "", "Candidate tasks:"])
    for item in candidates[:20]:
        recovery_suffix = ""
        recovery_pr = item.get("recoveryPr") if isinstance(item.get("recoveryPr"), dict) else None
        if item.get("recoveryReason") == "testing-open-pr" and recovery_pr:
            recovery_suffix = (
                f" [TESTING_OPEN_PR_RECOVERY from {item.get('originalStatus')} via "
                f"{recovery_pr.get('repo')}#{recovery_pr.get('number')}]"
            )
        lines.append(
            f"- {item['identifier']} [{item['status']}] {item['title']} "
            f"(project={item['project']}, taskId={item['taskId']}, updatedAt={item['updatedAt']})"
            f"{recovery_suffix}"
        )
    recovery_items = [item for item in candidates if item.get("recoveryReason") == "testing-open-pr"]
    if recovery_items:
        lines.extend(
            [
                "",
                "Testing open-PR recovery:",
                (
                    "- Start notices and completion summaries must state this is an open-PR recovery "
                    "from `testing`, not a normal Kimi testing/QA handoff."
                ),
                "- After PR merge, branch cleanup, and live-readiness, return the task to `testing` for Kimi QA.",
            ]
        )
    if prs:
        lines.extend(["", "Open GitHub PRs:"])
        for pr in prs[:20]:
            action_tag = pr["recommendedAction"]
            merge_tag = pr["mergeability"]
            merge_state_tag = pr["mergeState"]
            checks_tag = pr["checks"]
            draft_tag = "[DRAFT] " if pr["isDraft"] else ""
            task_done_flag = " [TASK_DONE_PR_OPEN]" if pr["taskDonePrOpen"] else ""
            linked = pr["linkedTaskIdentifier"] or "no linked task"
            lines.append(
                f"- {pr['repo']}#{pr['number']}: {draft_tag}{pr['title']} "
                f"[action={action_tag}, mergeability={merge_tag} ({merge_state_tag}), "
                f"checks={checks_tag}, linked={linked}]"
                f"{task_done_flag}"
                f" (branch={pr['headRef']}, updatedAt={pr['updatedAt']})"
            )
    lines.extend(
        [
            "",
            "Act in GPT-5.5 high only if this needs promotion/review/rework/merge judgment. "
            "The sentinel performed no GitHub mutations, merges, or QA claims. Kaneo mutations are limited "
            "to testing open-PR recovery status/notice reconciliation when reported above.",
        ]
    )
    return "\n".join(lines)


def escalate(openclaw_bin: str, model: str, message: str, timeout_seconds: int, *, state_dir: str) -> dict[str, Any]:
    proc = subprocess.run(
        [
            openclaw_bin,
            "agent",
            "--model",
            model,
            "--thinking",
            "high",
            "--timeout",
            str(timeout_seconds),
            "--message",
            message,
            "--json",
        ],
        text=True,
        capture_output=True,
        timeout=timeout_seconds + 20,
        check=False,
        env=openclaw_env(state_dir),
    )
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout.strip()[:2000],
        "stderr": proc.stderr.strip()[:2000],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--env-file", default=DEFAULT_ENV)
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--log", default=DEFAULT_LOG)
    parser.add_argument("--openclaw-bin", default=DEFAULT_OPENCLAW)
    parser.add_argument("--openclaw-state-dir", default=DEFAULT_OPENCLAW_STATE_DIR)
    parser.add_argument("--fireworks-base-url", default=DEFAULT_FIREWORKS_BASE_URL)
    parser.add_argument("--kimi-model", default=DEFAULT_KIMI_MODEL)
    parser.add_argument("--escalation-model", default=DEFAULT_ESCALATION_MODEL)
    parser.add_argument("--symphony-url", default="http://127.0.0.1:4057/api/v1/state")
    parser.add_argument("--reminder-seconds", type=int, default=DEFAULT_REMINDER_SECONDS)
    parser.add_argument("--max-candidates", type=int, default=40)
    parser.add_argument("--max-prs", type=int, default=50, help="Max open PRs to collect across all repos.")
    parser.add_argument("--gh-home", default=os.environ.get("SYMPHONY_SENTINEL_GH_HOME"))
    parser.add_argument("--skip-dynamic-projects", action="store_true", help="Only use projects from WORKFLOW.md.")
    parser.add_argument("--skip-prs", action="store_true", help="Skip GitHub PR scanning.")
    parser.add_argument(
        "--no-kaneo-recovery-mutations",
        action="store_true",
        help="Do not move testing tasks with open same-ticket PRs back to in-review or post recovery notes.",
    )
    parser.add_argument("--escalate", action="store_true", help="Wake GPT-5.5 high when changed actionable work is found.")
    parser.add_argument("--force-reminder", action="store_true")
    parser.add_argument("--always-classify", action="store_true", help="Run Kimi even when dedupe says the snapshot is unchanged.")
    parser.add_argument("--no-state-write", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="Do not wake GPT-5.5; still runs Kimi and reports the decision.")
    parser.add_argument("--timeout-seconds", type=int, default=600)
    args = parser.parse_args()

    load_env_file(Path(args.env_file))
    api_key = os.environ.get("KANEO_API_KEY")
    if not api_key:
        print(json.dumps({"ok": False, "error": "KANEO_API_KEY missing after env load"}))
        return 2

    endpoint, configured_projects = parse_workflow_projects(Path(args.workflow))
    project_discovery_errors: list[str] = []
    if args.skip_dynamic_projects:
        projects = configured_projects
        discovery_mode = "workflow"
    else:
        discovered_projects, project_discovery_errors = discover_kaneo_projects(endpoint, api_key)
        projects = merge_project_sources(discovered_projects, configured_projects)
        discovery_mode = "dynamic"
    symphony_state, symphony_error = fetch_optional_json(args.symphony_url)
    probe = summarize_symphony_state(symphony_state, symphony_error)
    probe["projectDiscovery"] = {
        "mode": discovery_mode,
        "dynamicCount": len(projects) if discovery_mode == "dynamic" else 0,
        "workflowFallbackCount": len(configured_projects),
    }
    if project_discovery_errors:
        probe["projectDiscoveryErrors"] = project_discovery_errors[:8]
    candidates, project_errors, all_tasks_map = collect_candidates(
        endpoint,
        projects,
        api_key=api_key,
        max_candidates=args.max_candidates,
    )
    if project_errors:
        probe["projectErrors"] = project_errors[:8]

    # Collect open GitHub PRs from all repos in the workflow
    prs: list[dict[str, Any]] = []
    pr_errors: list[str] = []
    if not args.skip_prs:
        prs, pr_errors = collect_github_prs(projects, all_tasks_map, max_prs=args.max_prs, gh_home=args.gh_home)
    if pr_errors:
        probe["prErrors"] = pr_errors[:8]
    testing_open_pr_recoveries = testing_open_pr_recovery_candidates(prs, all_tasks_map, candidates)
    recovery_results = reconcile_testing_open_pr_recoveries(
        endpoint,
        api_key,
        testing_open_pr_recoveries,
        dry_run=args.dry_run,
        mutate=not args.no_kaneo_recovery_mutations,
    )
    if testing_open_pr_recoveries:
        candidates.extend(testing_open_pr_recoveries)
        probe["testingOpenPrRecoveryCodes"] = [
            str(item.get("identifier")) for item in testing_open_pr_recoveries if item.get("identifier")
        ]
        probe["testingOpenPrRecoveryResults"] = recovery_results

    signature, normalized_candidates, normalized_prs = signature_for(candidates, probe, prs)
    state_path = Path(args.state)
    state = load_state(state_path)
    run_state = state.setdefault("signatures", {})
    do_escalate, reason = should_escalate(
        state,
        signature,
        reminder_seconds=args.reminder_seconds,
        force=args.force_reminder,
    )
    # PR-only actionable state should still trigger classification when meaningful
    actionable_prs = [
        pr
        for pr in prs
        if pr["recommendedAction"] not in ("await draft readiness", "wait for checks")
        or "stale" in pr.get("flags", [])
        or "conflicted" in pr.get("flags", [])
    ]
    if not candidates and not project_errors and not actionable_prs and not (probe.get("runningCount") or probe.get("retryingCount")):
        do_escalate, reason = False, "idle"

    if do_escalate or args.always_classify:
        kimi = run_kimi(
            args.kimi_model,
            candidates,
            probe,
            prs,
            fireworks_base_url=args.fireworks_base_url,
            state_dir=args.openclaw_state_dir,
        )
    else:
        kimi = {
            "ok": True,
            "model": args.kimi_model,
            "provider": "fireworks",
            "runtime": "direct-fireworks-chat-completions",
            "skipped": True,
            "classification": {
                "actionable": False,
                "summary": f"Kimi skipped because snapshot decision is {reason}.",
                "decision_points": [],
            },
            "stderr": "",
        }
    classification = kimi.get("classification") if isinstance(kimi, dict) else None
    kimi_actionable = bool(isinstance(classification, dict) and classification.get("actionable") is True)
    should_wake_main = bool(do_escalate and kimi_actionable)
    wake_message = build_wake_message(candidates, probe, prs, kimi, reason) if should_wake_main else ""
    escalation_result = None
    if should_wake_main and args.escalate and not args.dry_run:
        escalation_result = escalate(
            args.openclaw_bin,
            args.escalation_model,
            wake_message,
            args.timeout_seconds,
            state_dir=args.openclaw_state_dir,
        )

    now = iso_now()
    run_state.setdefault(signature, {"firstSeenAt": now})
    run_state[signature].update(
        {
            "lastSeenAt": now,
            "lastReason": reason,
            "candidateCount": len(candidates),
            "prCount": len(prs),
            "actionablePrCount": len(actionable_prs),
            "testingOpenPrRecoveryCount": len(testing_open_pr_recoveries),
            "normalized": normalized_candidates[: args.max_candidates],
            "normalizedPrs": normalized_prs[: args.max_prs],
        }
    )
    if should_wake_main and (args.escalate and not args.dry_run):
        run_state[signature]["lastEscalatedAt"] = now
    elif do_escalate and not args.dry_run:
        run_state[signature]["lastClassifiedAt"] = now
    elif do_escalate and args.dry_run:
        run_state[signature].setdefault("lastDryRunAt", now)
    state.update(
        {
            "version": 1,
            "lastRunAt": now,
            "lastSignature": signature,
            "lastDecision": reason,
            "lastCandidateCount": len(candidates),
            "lastPrCount": len(prs),
            "lastActionablePrCount": len(actionable_prs),
            "lastTestingOpenPrRecoveryCount": len(testing_open_pr_recoveries),
            "lastKimiOk": bool(kimi.get("ok")),
            "lastKimiSkipped": bool(kimi.get("skipped")),
        }
    )
    if not args.no_state_write:
        write_json(state_path, state)
    event = {
        "ts": now,
        "signature": signature,
        "candidateCount": len(candidates),
        "prCount": len(prs),
        "actionablePrCount": len(actionable_prs),
        "testingOpenPrRecoveryCount": len(testing_open_pr_recoveries),
        "decision": reason,
        "wouldEscalate": bool(should_wake_main),
        "kimiActionable": bool(kimi_actionable),
        "escalated": bool(escalation_result and escalation_result.get("ok")),
        "kimiOk": bool(kimi.get("ok")),
    }
    append_log(Path(args.log), event)
    output = {
        "ok": True,
        "endpoint": endpoint,
        "projectCount": len(projects),
        "candidateCount": len(candidates),
        "prCount": len(prs),
        "actionablePrCount": len(actionable_prs),
        "testingOpenPrRecoveryCount": len(testing_open_pr_recoveries),
        "testingOpenPrRecoveryResults": recovery_results,
        "signature": signature,
        "decision": reason,
        "wouldEscalate": bool(should_wake_main),
        "kimiActionable": bool(kimi_actionable),
        "dryRun": bool(args.dry_run),
        "kimi": {
            "ok": kimi.get("ok"),
            "model": kimi.get("model"),
            "provider": kimi.get("provider"),
            "runtime": kimi.get("runtime"),
            "authSource": kimi.get("authSource"),
            "finishReason": kimi.get("finishReason"),
            "skipped": bool(kimi.get("skipped")),
            "classification": kimi.get("classification"),
            "stderr": kimi.get("stderr") if not kimi.get("ok") else "",
        },
        "escalation": escalation_result,
        "wakeMessage": wake_message if args.dry_run else "",
        "candidates": [
            {
                "identifier": item["identifier"],
                "status": item["status"],
                "title": item["title"],
                "project": item["project"],
                "updatedAt": item["updatedAt"],
                "originalStatus": item.get("originalStatus"),
                "recoveryReason": item.get("recoveryReason"),
                "recoveryPr": item.get("recoveryPr"),
            }
            for item in candidates
        ],
        "prs": [
            {
                "repo": pr["repo"],
                "number": pr["number"],
                "title": pr["title"],
                "action": pr["action"],
                "recommendedAction": pr["recommendedAction"],
                "checks": pr["checks"],
                "mergeable": pr["mergeable"],
                "mergeability": pr["mergeability"],
                "mergeState": pr["mergeState"],
                "isDraft": pr["isDraft"],
                "flags": pr["flags"],
                "linkedTaskIdentifier": pr["linkedTaskIdentifier"],
                "linkedTaskStatus": pr["linkedTaskStatus"],
                "taskDonePrOpen": pr["taskDonePrOpen"],
            }
            for pr in prs
        ],
        "probe": probe,
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    if escalation_result and not escalation_result.get("ok"):
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
