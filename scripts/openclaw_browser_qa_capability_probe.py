#!/usr/bin/env python3
"""Probe OpenClaw browser and Telegram QA capabilities for worker sessions."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_BROWSER_URL = "http://127.0.0.1:9222"
DEFAULT_CHROME_PROFILE = "/Users/borodutch/Library/Application Support/Symphony/telegram-web-qa-chrome"
REQUIRED_COMPUTER_USE_TOOLS = [
    "mcp__computer_use__get_app_state",
    "mcp__computer_use__click",
    "mcp__computer_use__type_text",
    "mcp__computer_use__press_key",
]


def run_command(args: list[str], timeout: int = 30) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return {
            "ok": False,
            "command": args,
            "returncode": 127,
            "stdout": "",
            "stderr": f"{args[0]} not found",
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "command": args,
            "returncode": None,
            "stdout": exc.stdout or "",
            "stderr": f"timed out after {timeout}s",
        }

    return {
        "ok": completed.returncode == 0,
        "command": args,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def parse_json(text: str) -> Any | None:
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def fetch_json(url: str, timeout: int = 3) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return {
                "ok": 200 <= response.status < 300,
                "status": response.status,
                "json": parse_json(body),
                "error": None,
            }
    except urllib.error.HTTPError as exc:
        return {"ok": False, "status": exc.code, "json": None, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 - surfaced in the machine-readable report.
        return {"ok": False, "status": None, "json": None, "error": str(exc)}


def command_version(command: str, *args: str) -> dict[str, Any]:
    path = shutil.which(command)
    result = {
        "available": bool(path),
        "path": path,
        "version": None,
        "error": None,
    }
    if not path:
        return result

    completed = run_command([command, *args], timeout=10)
    if completed["ok"]:
        result["version"] = completed["stdout"].strip() or completed["stderr"].strip()
    else:
        result["error"] = completed["stderr"].strip() or completed["stdout"].strip()
    return result


def probe_peekaboo(skip_capture: bool, window_title: str | None) -> dict[str, Any]:
    script = Path(__file__).resolve().parent / "openclaw_peekaboo_healthcheck.py"
    base = {
        "healthcheck_script": str(script),
        "healthcheck_script_exists": script.exists(),
        "cli": command_version("peekaboo", "--version"),
        "ready": False,
        "report": None,
        "error": None,
    }

    if not script.exists():
        base["error"] = "scripts/openclaw_peekaboo_healthcheck.py is missing"
        return base

    command = [sys.executable, str(script), "--json"]
    if skip_capture:
        command.append("--skip-capture")
    if window_title:
        command.extend(["--window-title", window_title])

    completed = run_command(command, timeout=75)
    payload = parse_json(completed["stdout"])
    base["command"] = command
    base["returncode"] = completed["returncode"]
    base["ready"] = bool(completed["ok"] and isinstance(payload, dict) and payload.get("ready"))
    base["report"] = payload
    base["stderr"] = completed["stderr"].strip()
    if not isinstance(payload, dict):
        base["error"] = "healthcheck did not emit JSON"
    return base


def probe_cdp(browser_url: str) -> dict[str, Any]:
    version = fetch_json(f"{browser_url.rstrip('/')}/json/version")
    targets = fetch_json(f"{browser_url.rstrip('/')}/json/list")
    target_items = targets.get("json") if isinstance(targets.get("json"), list) else []
    telegram_targets = [
        {
            "id": item.get("id"),
            "title": item.get("title"),
            "url": item.get("url"),
            "type": item.get("type"),
        }
        for item in target_items
        if "web.telegram.org" in str(item.get("url", ""))
    ]
    return {
        "browser_url": browser_url,
        "devtools_available": bool(version["ok"]),
        "version": version,
        "target_count": len(target_items),
        "telegram_targets": telegram_targets,
        "telegram_web_visible": bool(telegram_targets),
    }


def probe_repo_helpers(start: Path) -> dict[str, Any]:
    candidates = []
    for root in [start, *start.parents]:
        helper = root / "scripts" / "telegram_web_qa.mjs"
        if helper.exists():
            candidates.append(str(helper))
        if root.name == "symphony-workspaces":
            break
    return {
        "telegram_cdp_helper_paths": candidates,
        "telegram_cdp_helper_available": bool(candidates),
        "node": command_version("node", "--version"),
        "python3": command_version("python3", "--version"),
    }


def probe_chrome(profile: str, browser_url: str) -> dict[str, Any]:
    home = os.environ.get("HOME")
    chrome_app = Path("/Applications/Google Chrome.app")
    profile_path = Path(profile).expanduser()
    launch_command = [
        "HOME=/Users/borodutch",
        "open",
        "-na",
        "Google Chrome",
        "--args",
        f"--remote-debugging-port={browser_url.rsplit(':', 1)[-1]}",
        f"--user-data-dir={profile}",
        "https://web.telegram.org/k/",
    ]
    return {
        "home": home,
        "home_uses_real_macos_keychain": home == "/Users/borodutch",
        "chrome_app_exists": chrome_app.exists(),
        "telegram_qa_profile": str(profile_path),
        "telegram_qa_profile_exists": profile_path.exists(),
        "real_profile_boundary": "Use HOME=/Users/borodutch for logged-in QA profiles; use --use-mock-keychain only for disposable throwaway profiles.",
        "safe_launch_command": shlex.join(launch_command),
    }


def probe_computer_use(mode: str) -> dict[str, Any]:
    env_value = (
        os.environ.get("OPENCLAW_COMPUTER_USE_AVAILABLE")
        or os.environ.get("CODEX_COMPUTER_USE_AVAILABLE")
        or ""
    ).strip().lower()
    if mode == "auto":
        if env_value in {"1", "true", "yes", "available"}:
            status = "available"
        elif env_value in {"0", "false", "no", "unavailable"}:
            status = "unavailable"
        else:
            status = "prompt_tool_check_required"
    else:
        status = mode

    return {
        "status": status,
        "shell_probeable": False,
        "required_prompt_tools": REQUIRED_COMPUTER_USE_TOOLS,
        "operator_check": (
            "Computer Use is available only when the worker prompt/tool list exposes "
            "`mcp__computer_use__.*` tools. If those tools are absent, record this "
            "probe output and escalate instead of claiming the capability failed."
        ),
    }


def redacted_environment() -> dict[str, Any]:
    def presence(name: str) -> dict[str, Any]:
        value = os.environ.get(name)
        return {
            "present": value is not None,
            "nonempty": bool(value),
        }

    return {
        "SYMPHONY_WORKFLOW_FILE": os.environ.get("SYMPHONY_WORKFLOW_FILE"),
        "SOURCE_REPO_URL": os.environ.get("SOURCE_REPO_URL"),
        "SOURCE_REPO_KEY": presence("SOURCE_REPO_KEY"),
        "SOURCE_REPO_KEYS": presence("SOURCE_REPO_KEYS"),
        "KANEO_PROJECT_ID": os.environ.get("KANEO_PROJECT_ID"),
    }


def remediation(report: dict[str, Any]) -> list[str]:
    steps: list[str] = []
    chrome = report["chrome"]
    if not chrome["home_uses_real_macos_keychain"]:
        steps.append("Launch logged-in Chrome QA profiles with `HOME=/Users/borodutch` so Chrome uses the real macOS login keychain.")
    if not chrome["telegram_qa_profile_exists"]:
        steps.append(f"Create or select the approved logged-in Telegram Web QA profile at `{chrome['telegram_qa_profile']}`.")
    if not report["cdp"]["devtools_available"]:
        steps.append(f"Launch Chrome with remote debugging at `{report['cdp']['browser_url']}` before using a repo CDP helper.")
    if report["cdp"]["devtools_available"] and not report["cdp"]["telegram_web_visible"]:
        steps.append("Open Telegram Web in the remote-debugging Chrome profile and confirm it is logged in.")
    peekaboo_report = report["peekaboo"].get("report") or {}
    for step in peekaboo_report.get("remediation", []) if isinstance(peekaboo_report, dict) else []:
        if step not in steps:
            steps.append(step)
    if report["computer_use"]["status"] == "prompt_tool_check_required":
        steps.append("Check the worker tool list for `mcp__computer_use__.*`; if absent, route to a main-session QA helper.")
    return steps


def choose_path(report: dict[str, Any]) -> dict[str, Any]:
    helpers = report["repo_helpers"]
    cdp = report["cdp"]
    peekaboo = report["peekaboo"]
    computer_use = report["computer_use"]

    if helpers["telegram_cdp_helper_available"] and cdp["devtools_available"] and cdp["telegram_web_visible"]:
        return {
            "kind": "repo_telegram_cdp_helper",
            "ready": True,
            "command": f"node {helpers['telegram_cdp_helper_paths'][0]} --browser-url {cdp['browser_url']} --chat <target> --message <timestamped-message> --json",
        }
    if peekaboo["ready"]:
        return {
            "kind": "peekaboo",
            "ready": True,
            "command": "python3 scripts/openclaw_peekaboo_telegram_smoke.py --wait-ready-seconds 300 --json",
        }
    if computer_use["status"] == "available":
        return {
            "kind": "codex_computer_use",
            "ready": True,
            "command": "Use `mcp__computer_use__get_app_state` on Google Chrome, then interact with the UI and attach screenshots/evidence.",
        }
    return {
        "kind": "main_session_qa_helper_escalation",
        "ready": False,
        "command": "Post the structured blocker below in the Kaneo workpad and request main-session browser QA.",
    }


def blocker_message(report: dict[str, Any]) -> str:
    path = report["supported_path"]
    tried = [
        f"Peekaboo healthcheck ready={json_bool(report['peekaboo']['ready'])}",
        f"Chrome CDP {report['cdp']['browser_url']} available={json_bool(report['cdp']['devtools_available'])} telegram_target={json_bool(report['cdp']['telegram_web_visible'])}",
        f"Computer Use status={report['computer_use']['status']}",
    ]
    needed = report["remediation"] or ["No environment remediation identified; inspect the JSON probe details."]
    return "\n".join(
        [
            "Browser QA capability probe result:",
            f"- Direct QA path: {path['kind']} (ready={json_bool(path['ready'])})",
            f"- Fallback tried: {'; '.join(tried)}",
            f"- Environment change needed: {'; '.join(needed)}",
            "- Boundary: use only the approved Telegram/browser QA profile; do not inspect or export private browser data or credentials.",
        ]
    )


def json_bool(value: Any) -> str:
    return "true" if bool(value) else "false"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report browser and Telegram QA readiness for OpenClaw/Symphony workers."
    )
    parser.add_argument("--browser-url", default=DEFAULT_BROWSER_URL)
    parser.add_argument("--chrome-profile", default=DEFAULT_CHROME_PROFILE)
    parser.add_argument("--window-title", default="Telegram Web")
    parser.add_argument(
        "--computer-use",
        choices=["auto", "available", "unavailable"],
        default="auto",
        help="Use `available` only when the worker tool list exposes mcp__computer_use__ tools.",
    )
    parser.add_argument("--skip-peekaboo-capture", action="store_true")
    parser.add_argument("--fail-when-not-ready", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    cwd = Path.cwd()
    report: dict[str, Any] = {
        "schema": "openclaw.browser_qa_capability.v1",
        "cwd": str(cwd),
        "environment": redacted_environment(),
        "chrome": probe_chrome(args.chrome_profile, args.browser_url),
        "repo_helpers": probe_repo_helpers(cwd),
        "cdp": probe_cdp(args.browser_url),
        "peekaboo": probe_peekaboo(args.skip_peekaboo_capture, args.window_title),
        "computer_use": probe_computer_use(args.computer_use),
    }
    report["remediation"] = remediation(report)
    report["supported_path"] = choose_path(report)
    report["qa_ready"] = bool(report["supported_path"]["ready"])
    report["expected_blocker_message"] = blocker_message(report)

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("# OpenClaw Browser QA Capability Probe")
        print(f"- Ready: {'yes' if report['qa_ready'] else 'no'}")
        print(f"- Supported path: {report['supported_path']['kind']}")
        print(f"- Command: `{report['supported_path']['command']}`")
        if report["remediation"]:
            print("- Remediation:")
            for step in report["remediation"]:
                print(f"  - {step}")
        if not report["qa_ready"]:
            print("")
            print(report["expected_blocker_message"])

    if args.fail_when_not_ready and not report["qa_ready"]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
