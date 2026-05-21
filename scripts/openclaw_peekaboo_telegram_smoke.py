#!/usr/bin/env python3
"""Run a Peekaboo-only Telegram Web smoke test against a real account."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from openclaw_peekaboo_healthcheck import image_pixel_summary


def run_command(args: list[str], timeout: int = 45) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
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


def json_stdout(result: dict[str, Any]) -> dict[str, Any] | None:
    if not result["stdout"].strip():
        return None
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError:
        return None


def command_output(result: dict[str, Any]) -> dict[str, Any]:
    payload = json_stdout(result)
    return {
        "ok": result["ok"],
        "returncode": result["returncode"],
        "json": payload,
        "stderr": result["stderr"].strip(),
    }


def make_message(prefix: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"{prefix} {stamp}"


def normalize_coords(value: str) -> str:
    try:
        x_raw, y_raw = value.split(",", 1)
        x = int(x_raw.strip())
        y = int(y_raw.strip())
    except ValueError as exc:
        raise ValueError("expected x,y integer coordinates") from exc
    if x < 0 or y < 0:
        raise ValueError("coordinates must be non-negative")
    return f"{x},{y}"


def capture(app: str, window_title: str, path: Path) -> dict[str, Any]:
    return run_command(
        [
            "peekaboo",
            "see",
            "--app",
            app,
            "--window-title",
            window_title,
            "--path",
            str(path),
            "--json",
        ],
        timeout=45,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Use Peekaboo to send and verify a timestamped Telegram Web message."
    )
    parser.add_argument("--bot", default="@okamikron_bot", help="Telegram bot username to open.")
    parser.add_argument("--app", default="Google Chrome", help="Browser app name.")
    parser.add_argument("--window-title", default="Telegram Web", help="Telegram Web window title.")
    parser.add_argument("--input-query", default="Message", help="Peekaboo query for the message field.")
    parser.add_argument(
        "--input-coords",
        help="Optional x,y coordinate fallback for the message field when browser accessibility exposes no input elements.",
    )
    parser.add_argument("--message-prefix", default="OpenClaw Peekaboo QA", help="Message prefix.")
    parser.add_argument("--output-dir", default="tmp", help="Directory for screenshots and JSON evidence.")
    parser.add_argument("--report-path", help="Optional path for the final smoke report JSON.")
    parser.add_argument(
        "--wait-ready-seconds",
        type=int,
        default=0,
        help="Wait up to this many seconds for the healthcheck to become ready before failing.",
    )
    parser.add_argument(
        "--wait-interval-seconds",
        type=int,
        default=15,
        help="Seconds between healthcheck attempts while waiting.",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    args = parser.parse_args()
    if args.input_coords:
        try:
            args.input_coords = normalize_coords(args.input_coords)
        except ValueError as exc:
            parser.error(f"--input-coords {exc}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    message = make_message(args.message_prefix)
    safe_stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    before_path = output_dir / f"peekaboo-telegram-before-{safe_stamp}.png"
    after_path = output_dir / f"peekaboo-telegram-after-{safe_stamp}.png"
    health_path = output_dir / f"peekaboo-telegram-health-{safe_stamp}.json"
    report_path = Path(args.report_path) if args.report_path else output_dir / f"peekaboo-telegram-report-{safe_stamp}.json"
    url = f"https://web.telegram.org/k/#{args.bot}"

    report: dict[str, Any] = {
        "bot": args.bot,
        "url": url,
        "message": message,
        "before_screenshot": str(before_path),
        "after_screenshot": str(after_path),
        "report_json": str(report_path),
        "input_coords": args.input_coords,
        "steps": {},
    }

    health = wait_for_healthcheck(args.window_title, max(0, args.wait_ready_seconds), max(1, args.wait_interval_seconds), report)
    health_payload = json_stdout(health)
    health_path.write_text(json.dumps(health_payload or command_output(health), indent=2), encoding="utf-8")
    report["steps"]["healthcheck"] = command_output(health)
    report["healthcheck_summary"] = summarize_healthcheck(health_payload)
    report["healthcheck_json"] = str(health_path)
    if not health["ok"]:
        report["ok"] = False
        report["blocked"] = "healthcheck_failed"
        report["blocked_reason"] = (health_payload or {}).get("blocked_reason")
        report["fallback"] = (health_payload or {}).get("fallback")
        report["remediation"] = (health_payload or {}).get("remediation")
        return finish(report, args.json, code=2, report_path=report_path)

    report["steps"]["open"] = command_output(
        run_command(["peekaboo", "open", url, "--app", args.app, "--wait-until-ready", "--json"], timeout=30)
    )
    time.sleep(2)

    focus_result = run_command(
        [
            "peekaboo",
            "window",
            "focus",
            "--app",
            args.app,
            "--window-title",
            args.window_title,
            "--no-remote",
            "--json",
        ],
        timeout=30,
    )
    report["steps"]["focus"] = command_output(focus_result)

    before = capture(args.app, args.window_title, before_path)
    before_pixels = image_pixel_summary(before_path)
    report["steps"]["capture_before"] = command_output(before)
    report["before_screenshot_pixel_summary"] = before_pixels
    if not before["ok"] or not before_path.exists() or before_path.stat().st_size == 0:
        report["ok"] = False
        report["blocked"] = "telegram_window_capture_failed"
        return finish(report, args.json, code=3, report_path=report_path)
    if not before_pixels.get("nonblack"):
        report["ok"] = False
        report["blocked"] = "telegram_window_capture_black"
        report["blocked_reason"] = "blank_or_black_capture"
        return finish(report, args.json, code=3, report_path=report_path)

    click = run_command(
        [
            "peekaboo",
            "click",
            args.input_query,
            "--app",
            args.app,
            "--window-title",
            args.window_title,
            "--bring-to-current-space",
            "--wait-for",
            "10000",
            "--json",
        ],
        timeout=30,
    )
    report["steps"]["click_input"] = command_output(click)
    type_no_remote = False
    if not click["ok"]:
        if not args.input_coords:
            report["ok"] = False
            report["blocked"] = "message_input_not_found"
            return finish(report, args.json, code=4, report_path=report_path)
        click = run_command(
            [
                "peekaboo",
                "click",
                "--coords",
                args.input_coords,
                "--app",
                args.app,
                "--window-title",
                args.window_title,
                "--no-remote",
                "--json",
            ],
            timeout=30,
        )
        report["steps"]["click_input_coords"] = command_output(click)
        if not click["ok"]:
            report["ok"] = False
            report["blocked"] = "message_input_not_found"
            return finish(report, args.json, code=4, report_path=report_path)
        type_no_remote = True

    type_command = [
        "peekaboo",
        "type",
        "--text",
        message,
        "--clear",
        "--return",
        "--app",
        args.app,
        "--window-title",
        args.window_title,
    ]
    if type_no_remote:
        type_command.append("--no-remote")
    type_command.append("--json")
    typed = run_command(type_command, timeout=30)
    report["steps"]["type_message"] = command_output(typed)
    if not typed["ok"]:
        report["ok"] = False
        report["blocked"] = "message_type_failed"
        return finish(report, args.json, code=5, report_path=report_path)

    time.sleep(3)
    after = capture(args.app, args.window_title, after_path)
    after_payload = json_stdout(after)
    after_pixels = image_pixel_summary(after_path)
    report["steps"]["capture_after"] = command_output(after)
    report["message_visible_in_ui_json"] = message in json.dumps(after_payload or {}, ensure_ascii=False)
    report["after_screenshot_bytes"] = after_path.stat().st_size if after_path.exists() else 0
    report["after_screenshot_pixel_summary"] = after_pixels
    report["ok"] = bool(
        after["ok"]
        and report["after_screenshot_bytes"] > 0
        and after_pixels.get("nonblack")
        and report["message_visible_in_ui_json"]
    )
    if not report["ok"]:
        if not after_pixels.get("nonblack"):
            report["blocked"] = "telegram_window_capture_black"
            report["blocked_reason"] = "blank_or_black_capture"
        else:
            report["blocked"] = "message_not_verified_in_peekaboo_ui_json"
    return finish(report, args.json, code=0 if report["ok"] else 6, report_path=report_path)


def wait_for_healthcheck(window_title: str, wait_seconds: int, interval_seconds: int, report: dict[str, Any]) -> dict[str, Any]:
    deadline = time.monotonic() + wait_seconds
    attempts = []

    while True:
        result = run_command(
            [
                sys.executable,
                "scripts/openclaw_peekaboo_healthcheck.py",
                "--window-title",
                window_title,
                "--json",
            ],
            timeout=60,
        )
        payload = json_stdout(result) or {}
        attempts.append(
            {
                "ok": result["ok"],
                "ready": payload.get("ready"),
                "blocked_reason": payload.get("blocked_reason"),
                "fallback": payload.get("fallback"),
                "blocked_app": payload.get("screen_probe", {}).get("application_name"),
                "input_surface_app": payload.get("input_surface", {}).get("application_name"),
                "input_surface_ok": payload.get("input_surface", {}).get("ok"),
                "user_is_active": payload.get("system", {}).get("user_is_active"),
                "capture_blocked_reason": payload.get("capture", {}).get("blocked_reason"),
                "capture_nonblack": payload.get("capture", {}).get("pixel_summary", {}).get("nonblack"),
                "screen_nonblack": payload.get("screen_probe", {}).get("pixel_summary", {}).get("nonblack"),
            }
        )
        report["healthcheck_attempts"] = attempts

        if result["ok"] or time.monotonic() >= deadline:
            return result

        time.sleep(min(interval_seconds, max(0.0, deadline - time.monotonic())))


def finish(report: dict[str, Any], as_json: bool, code: int, report_path: Path) -> int:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("# OpenClaw Peekaboo Telegram Smoke")
        print(f"- OK: {'yes' if report.get('ok') else 'no'}")
        print(f"- Bot: {report['bot']}")
        print(f"- Message: {report['message']}")
        print(f"- Report: `{report['report_json']}`")
        print(f"- Before screenshot: `{report['before_screenshot']}`")
        print(f"- After screenshot: `{report['after_screenshot']}`")
        if report.get("blocked"):
            print(f"- Blocked: {report['blocked']}")
    return code


def summarize_healthcheck(payload: dict[str, Any] | None) -> dict[str, Any]:
    payload = payload or {}
    return {
        "ready": payload.get("ready"),
        "blocked_reason": payload.get("blocked_reason"),
        "fallback": payload.get("fallback"),
        "remediation": payload.get("remediation"),
        "bridge_ok": payload.get("bridge", {}).get("ok"),
        "permissions_ok": payload.get("permissions", {}).get("ok"),
        "chrome_running": payload.get("apps", {}).get("chrome_running"),
        "capture_ok": payload.get("capture", {}).get("ok"),
        "capture_blocked_reason": payload.get("capture", {}).get("blocked_reason"),
        "capture_nonblack": payload.get("capture", {}).get("pixel_summary", {}).get("nonblack"),
        "screen_app": payload.get("screen_probe", {}).get("application_name"),
        "screen_nonblack": payload.get("screen_probe", {}).get("pixel_summary", {}).get("nonblack"),
    }


if __name__ == "__main__":
    sys.exit(main())
