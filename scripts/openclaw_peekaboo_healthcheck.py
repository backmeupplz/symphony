#!/usr/bin/env python3
"""Check whether Peekaboo is ready for OpenClaw UI and Telegram QA."""

from __future__ import annotations

import argparse
import binascii
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path
from typing import Any


REQUIRED_PERMISSIONS = {"Screen Recording", "Accessibility"}
NEAR_BLACK_CHANNEL = 12
NONBLACK_RATIO_MIN = 0.01


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


def simple_stdout(args: list[str], timeout: int = 10) -> str | None:
    result = run_command(args, timeout=timeout)
    if not result["ok"]:
        return None
    return result["stdout"].strip()


def parse_json_result(result: dict[str, Any]) -> dict[str, Any] | None:
    if not result["stdout"].strip():
        return None
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError:
        return None


def permission_summary(payload: dict[str, Any] | None) -> tuple[list[dict[str, Any]], list[str]]:
    permissions = []
    missing = []

    if payload:
        permissions = payload.get("data", {}).get("permissions", [])

    granted = {item.get("name") for item in permissions if item.get("isGranted")}
    for name in sorted(REQUIRED_PERMISSIONS):
        if name not in granted:
            missing.append(name)

    return permissions, missing


def chrome_running(payload: dict[str, Any] | None) -> bool:
    apps = []
    if payload:
        apps = payload.get("data", {}).get("applications", [])
    return any(app.get("bundleIdentifier") == "com.google.Chrome" for app in apps)


def bridge_summary(payload: dict[str, Any] | None, result: dict[str, Any]) -> dict[str, Any]:
    data = (payload or {}).get("data", {})
    selected = data.get("selected") or {}
    handshake = selected.get("handshake") or {}
    permissions = handshake.get("permissions") or {}
    client = data.get("client") or {}
    return {
        "ok": result["ok"] and bool(selected),
        "source": selected.get("source"),
        "socket_path": selected.get("socketPath"),
        "host_kind": handshake.get("hostKind"),
        "build": handshake.get("build"),
        "permissions": permissions,
        "client": {
            "bundle_identifier": client.get("bundleIdentifier"),
            "process_identifier": client.get("processIdentifier"),
            "hostname": client.get("hostname"),
            "team_identifier": client.get("teamIdentifier"),
        },
        "stderr": result["stderr"].strip(),
    }


def system_summary() -> dict[str, Any]:
    console_user = simple_stdout(["stat", "-f", "%Su", "/dev/console"])
    pmset = run_command(["pmset", "-g", "assertions"], timeout=10)
    user_is_active = None
    if pmset["ok"]:
        for line in pmset["stdout"].splitlines():
            stripped = line.strip()
            if stripped.startswith("UserIsActive"):
                parts = stripped.split()
                if len(parts) >= 2:
                    user_is_active = parts[-1] == "1"
                break

    return {
        "console_user": console_user,
        "user_is_active": user_is_active,
        "pmset_available": pmset["ok"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report Peekaboo readiness for OpenClaw UI and Telegram Web QA."
    )
    parser.add_argument(
        "--app",
        default="Google Chrome",
        help="Application to capture for the screenshot smoke test.",
    )
    parser.add_argument(
        "--window-title",
        help="Optional window title to target during the screenshot smoke test.",
    )
    parser.add_argument(
        "--skip-capture",
        action="store_true",
        help="Only check permissions and application visibility.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON.",
    )
    args = parser.parse_args()

    peekaboo_path = shutil.which("peekaboo")
    report: dict[str, Any] = {
        "peekaboo_path": peekaboo_path,
        "system": system_summary(),
        "bridge": {},
        "permissions": {},
        "apps": {},
        "capture": {"skipped": args.skip_capture},
        "input_surface": {"skipped": args.skip_capture},
        "telegram_policy": {
            "primary": "Use Peekaboo with Chrome/Telegram Web and a logged-in real account.",
            "not_allowed": "Do not validate Telegram bot UX by trying bot-to-bot messaging.",
            "fallback": "Use Codex Computer Use when Peekaboo is blocked; keep CDP/AppleScript/DOM scripting diagnostic-only.",
        },
    }

    if not peekaboo_path:
        report["ready"] = False
        report["remediation"] = ["Install or expose the peekaboo CLI on PATH."]
        print_report(report, args.json)
        return 1

    bridge_result = run_command(["peekaboo", "bridge", "status", "--json"], timeout=20)
    bridge_payload = parse_json_result(bridge_result)
    report["bridge"] = bridge_summary(bridge_payload, bridge_result)

    permissions_result = run_command(["peekaboo", "permissions", "--json"], timeout=20)
    permissions_payload = parse_json_result(permissions_result)
    permissions, missing_permissions = permission_summary(permissions_payload)
    report["permissions"] = {
        "ok": permissions_result["ok"] and not missing_permissions,
        "source": (permissions_payload or {}).get("data", {}).get("source"),
        "items": permissions,
        "missing_required": missing_permissions,
        "stderr": permissions_result["stderr"].strip(),
    }

    apps_result = run_command(["peekaboo", "list", "apps", "--json"], timeout=20)
    apps_payload = parse_json_result(apps_result)
    report["apps"] = {
        "ok": apps_result["ok"],
        "chrome_running": chrome_running(apps_payload),
        "stderr": apps_result["stderr"].strip(),
    }

    capture_ok = True
    if not args.skip_capture:
        with tempfile.NamedTemporaryFile(prefix="openclaw-peekaboo-", suffix=".png", delete=False) as file:
            screenshot_path = Path(file.name)

        capture_command = ["peekaboo", "see", "--app", args.app]
        if args.window_title:
            capture_command += ["--window-title", args.window_title]
        capture_command += ["--path", str(screenshot_path), "--json"]

        capture_result = run_command(capture_command, timeout=45)
        capture_payload = parse_json_result(capture_result)
        screenshot_size = screenshot_path.stat().st_size if screenshot_path.exists() else 0
        pixel_summary = image_pixel_summary(screenshot_path)
        capture_ok = bool(capture_result["ok"] and screenshot_size > 0 and pixel_summary.get("nonblack"))
        report["capture"] = {
            "ok": capture_ok,
            "app": args.app,
            "blocked_reason": capture_blocked_reason(capture_result, capture_payload, pixel_summary),
            "screenshot_path": str(screenshot_path),
            "screenshot_bytes": screenshot_size,
            "pixel_summary": pixel_summary,
            "snapshot_id": (capture_payload or {}).get("data", {}).get("snapshotId"),
            "error": (capture_payload or {}).get("error"),
            "stderr": capture_result["stderr"].strip(),
        }
        screen = screen_probe()
        report["screen_probe"] = screen
        report["input_surface"] = {
            "ok": bool(screen.get("ok") and screen.get("application_name") != "loginwindow"),
            "application_name": screen.get("application_name"),
            "window_title": screen.get("window_title"),
        }

    input_surface_ok = report["input_surface"].get("skipped") or report["input_surface"].get("ok")
    ready = bool(report["permissions"]["ok"] and report["apps"]["ok"] and capture_ok and input_surface_ok)
    report["ready"] = ready
    report["blocked_reason"] = blocked_reason(report)
    report["fallback"] = fallback_summary(report)
    report["remediation"] = remediation(report)

    print_report(report, args.json)
    return 0 if ready else 1


def remediation(report: dict[str, Any]) -> list[str]:
    steps = []
    if not report.get("bridge", {}).get("ok"):
        steps.append("Start or repair the OpenClaw/Peekaboo bridge so permission-bound UI operations have a GUI host.")
    if not report["permissions"].get("ok"):
        missing = ", ".join(report["permissions"].get("missing_required", [])) or "required permissions"
        bridge = report.get("bridge", {})
        owner = bridge.get("client", {}).get("bundle_identifier") or bridge.get("socket_path") or "the OpenClaw/Peekaboo runtime"
        steps.append(
            f"Grant {missing} to {owner} in System Settings > Privacy & Security, then restart the OpenClaw bridge."
        )
    if not report["apps"].get("chrome_running"):
        steps.append("Launch Google Chrome with the logged-in Telegram Web QA profile before running Telegram QA.")
    capture = report.get("capture", {})
    if capture and not capture.get("skipped") and not capture.get("ok"):
        screen_probe = report.get("screen_probe", {})
        if screen_probe.get("application_name") == "loginwindow":
            console_user = report.get("system", {}).get("console_user") or "the console user"
            steps.append(f"Unlock the macOS user session for {console_user}; Peekaboo currently sees `loginwindow`, so Chrome/Telegram Web is not capturable.")
        elif capture.get("blocked_reason") == "blank_or_black_capture":
            steps.append("Treat this as an unusable capture, even if the PNG file exists; rerun after bringing the target browser window to a visible unlocked desktop.")
        steps.append("Run `peekaboo see --app \"Google Chrome\" --json` and inspect the returned capture error.")
    input_surface = report.get("input_surface", {})
    if input_surface and not input_surface.get("skipped") and not input_surface.get("ok"):
        if input_surface.get("application_name") == "loginwindow" and report.get("capture", {}).get("ok"):
            console_user = report.get("system", {}).get("console_user") or "the console user"
            steps.append(f"Unlock the macOS user session for {console_user}; Peekaboo can capture Chrome, but input control is unsafe while `loginwindow` is frontmost.")
        elif input_surface.get("application_name") != "loginwindow":
            app = input_surface.get("application_name") or "another application"
            steps.append(f"Bring {report.get('capture', {}).get('app', 'the target app')} to the active desktop before input QA; the screen probe currently sees {app}.")
    return steps


def blocked_reason(report: dict[str, Any]) -> str | None:
    if report.get("ready"):
        return None
    if not report.get("bridge", {}).get("ok"):
        return "bridge_unavailable"
    if not report.get("permissions", {}).get("ok"):
        return "missing_permissions"
    if not report.get("apps", {}).get("chrome_running"):
        return "chrome_not_running"
    screen_probe = report.get("screen_probe", {})
    if screen_probe.get("application_name") == "loginwindow":
        return "macos_loginwindow"
    capture = report.get("capture", {})
    if capture and not capture.get("skipped") and not capture.get("ok"):
        return capture.get("blocked_reason") or "capture_failed"
    input_surface = report.get("input_surface", {})
    if input_surface and not input_surface.get("skipped") and not input_surface.get("ok"):
        return "input_surface_blocked"
    return "unknown"


def fallback_summary(report: dict[str, Any]) -> dict[str, Any]:
    if report.get("ready"):
        return {"required": False}
    reason = report.get("blocked_reason") or blocked_reason(report)
    if reason in {"blank_or_black_capture", "window_not_found", "capture_failed", "input_surface_blocked"}:
        return {
            "required": True,
            "path": "codex_computer_use",
            "why": "Peekaboo cannot produce a usable visible browser capture from this runtime.",
            "handoff": "Use Codex Computer Use from the main OpenClaw session for browser QA, or rerun after the remediation steps make Peekaboo ready.",
        }
    if reason == "macos_loginwindow":
        return {
            "required": False,
            "path": None,
            "why": "The console is locked; browser QA needs the user session unlocked before any UI automation path can safely click/type.",
        }
    return {
        "required": True,
        "path": "manual_or_computer_use",
        "why": f"Peekaboo healthcheck is blocked by {reason or 'unknown'} before browser QA.",
        "handoff": "Record this healthcheck JSON and use the approved manual or Codex Computer Use escalation path.",
    }


def capture_blocked_reason(
    result: dict[str, Any],
    payload: dict[str, Any] | None,
    pixel_summary: dict[str, Any],
) -> str | None:
    if result["ok"] and pixel_summary.get("nonblack"):
        return None
    error = (payload or {}).get("error") or {}
    code = str(error.get("code") or "").lower()
    message = str(error.get("message") or "").lower()
    if "window_not_found" in code or "target was not found" in message:
        return "window_not_found"
    if result["ok"] and not pixel_summary.get("nonblack"):
        return "blank_or_black_capture"
    if result["returncode"] is None:
        return "capture_timeout"
    return "capture_failed"


def screen_probe() -> dict[str, Any]:
    with tempfile.NamedTemporaryFile(prefix="openclaw-peekaboo-screen-", suffix=".png", delete=False) as file:
        screenshot_path = Path(file.name)

    result = run_command(
        [
            "peekaboo",
            "see",
            "--mode",
            "screen",
            "--screen-index",
            "0",
            "--path",
            str(screenshot_path),
            "--json",
        ],
        timeout=30,
    )
    payload = parse_json_result(result)
    data = (payload or {}).get("data", {})
    screenshot_size = screenshot_path.stat().st_size if screenshot_path.exists() else 0
    return {
        "ok": result["ok"],
        "application_name": data.get("application_name"),
        "window_title": data.get("window_title"),
        "screenshot_path": str(screenshot_path),
        "screenshot_bytes": screenshot_size,
        "pixel_summary": image_pixel_summary(screenshot_path),
        "error": (payload or {}).get("error"),
    }


def image_pixel_summary(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"ok": False, "error": "file_missing", "nonblack": False}
    if path.stat().st_size == 0:
        return {"ok": False, "error": "empty_file", "nonblack": False}

    try:
        pixels = decode_png_pixels(path)
    except Exception as exc:  # noqa: BLE001 - healthcheck must report diagnostics, not crash.
        return {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "nonblack": False,
        }

    total = max(1, pixels["width"] * pixels["height"])
    nonblack = 0
    max_channel = 0
    min_channel = 255
    luma_sum = 0.0
    for r, g, b, _a in pixels["rgba"]:
        max_channel = max(max_channel, r, g, b)
        min_channel = min(min_channel, r, g, b)
        if max(r, g, b) > NEAR_BLACK_CHANNEL:
            nonblack += 1
        luma_sum += (0.2126 * r) + (0.7152 * g) + (0.0722 * b)

    ratio = nonblack / total
    return {
        "ok": True,
        "width": pixels["width"],
        "height": pixels["height"],
        "bit_depth": pixels["bit_depth"],
        "color_type": pixels["color_type"],
        "pixels": total,
        "nonblack_pixels": nonblack,
        "nonblack_ratio": round(ratio, 6),
        "nonblack": bool(max_channel > NEAR_BLACK_CHANNEL and ratio >= NONBLACK_RATIO_MIN),
        "max_channel": max_channel,
        "min_channel": min_channel,
        "average_luma": round(luma_sum / total, 2),
    }


def decode_png_pixels(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a PNG file")

    offset = 8
    width = height = bit_depth = color_type = None
    compressed = bytearray()
    palette: list[tuple[int, int, int]] = []

    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        chunk_data = data[offset + 8:offset + 8 + length]
        crc_expected = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        crc_actual = binascii.crc32(chunk_type + chunk_data) & 0xFFFFFFFF
        if crc_actual != crc_expected:
            raise ValueError(f"bad PNG CRC in {chunk_type.decode('ascii', errors='replace')}")

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _compression, _filter, _interlace = struct.unpack(">IIBBBBB", chunk_data)
            if _interlace != 0:
                raise ValueError("interlaced PNG is not supported")
        elif chunk_type == b"PLTE":
            palette = [
                tuple(chunk_data[index:index + 3])
                for index in range(0, len(chunk_data), 3)
                if len(chunk_data[index:index + 3]) == 3
            ]
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break
        offset += 12 + length

    if None in {width, height, bit_depth, color_type}:
        raise ValueError("PNG header missing")
    if bit_depth != 8:
        raise ValueError(f"unsupported PNG bit depth {bit_depth}")

    channels_by_type = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    channels = channels_by_type.get(color_type)
    if channels is None:
        raise ValueError(f"unsupported PNG color type {color_type}")

    raw = zlib.decompress(bytes(compressed))
    row_bytes = width * channels
    stride = row_bytes + 1
    previous = bytearray(row_bytes)
    rows: list[bytearray] = []
    for row_index in range(height):
        start = row_index * stride
        filter_type = raw[start]
        scanline = bytearray(raw[start + 1:start + stride])
        recon = unfilter_scanline(scanline, previous, filter_type, channels)
        rows.append(recon)
        previous = recon

    rgba: list[tuple[int, int, int, int]] = []
    for row in rows:
        if color_type == 0:
            rgba.extend((v, v, v, 255) for v in row)
        elif color_type == 2:
            rgba.extend((row[i], row[i + 1], row[i + 2], 255) for i in range(0, len(row), 3))
        elif color_type == 3:
            for index in row:
                if index >= len(palette):
                    raise ValueError("PNG palette index out of range")
                r, g, b = palette[index]
                rgba.append((r, g, b, 255))
        elif color_type == 4:
            rgba.extend((row[i], row[i], row[i], row[i + 1]) for i in range(0, len(row), 2))
        elif color_type == 6:
            rgba.extend((row[i], row[i + 1], row[i + 2], row[i + 3]) for i in range(0, len(row), 4))

    return {
        "width": width,
        "height": height,
        "bit_depth": bit_depth,
        "color_type": color_type,
        "rgba": rgba,
    }


def unfilter_scanline(scanline: bytearray, previous: bytearray, filter_type: int, bytes_per_pixel: int) -> bytearray:
    recon = bytearray(len(scanline))
    for index, value in enumerate(scanline):
        left = recon[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
        up = previous[index] if index < len(previous) else 0
        up_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel and index < len(previous) else 0
        if filter_type == 0:
            recon[index] = value
        elif filter_type == 1:
            recon[index] = (value + left) & 0xFF
        elif filter_type == 2:
            recon[index] = (value + up) & 0xFF
        elif filter_type == 3:
            recon[index] = (value + ((left + up) // 2)) & 0xFF
        elif filter_type == 4:
            recon[index] = (value + paeth_predictor(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"unsupported PNG filter {filter_type}")
    return recon


def paeth_predictor(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    up_left_distance = abs(estimate - up_left)
    if left_distance <= up_distance and left_distance <= up_left_distance:
        return left
    if up_distance <= up_left_distance:
        return up
    return up_left


def print_report(report: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return

    print("# OpenClaw Peekaboo Healthcheck")
    print(f"- Ready: {'yes' if report.get('ready') else 'no'}")
    print(f"- Peekaboo: `{report.get('peekaboo_path') or 'not found'}`")
    system = report.get("system", {})
    if system:
        print(f"- Console user: {system.get('console_user') or 'unknown'}")
        if system.get("user_is_active") is not None:
            print(f"- User active assertion: {'yes' if system.get('user_is_active') else 'no'}")
    bridge = report.get("bridge", {})
    if bridge:
        print(f"- Bridge: {'ok' if bridge.get('ok') else 'blocked'}")
        if bridge.get("socket_path"):
            print(f"- Bridge socket: `{bridge['socket_path']}`")
        if bridge.get("build"):
            print(f"- Bridge build: {bridge['build']}")
        client = bridge.get("client") or {}
        if client.get("bundle_identifier"):
            print(f"- Bridge client: {client['bundle_identifier']} pid {client.get('process_identifier')}")
    permissions = report.get("permissions", {})
    print(f"- Permissions: {'ok' if permissions.get('ok') else 'blocked'}")
    if permissions.get("source"):
        print(f"- Permission source: {permissions['source']}")
    for item in permissions.get("items", []):
        mark = "ok" if item.get("isGranted") else "missing"
        required = "required" if item.get("isRequired") else "optional"
        print(f"  - {item.get('name')}: {mark} ({required})")
    apps = report.get("apps", {})
    print(f"- Chrome running: {'yes' if apps.get('chrome_running') else 'no'}")
    input_surface = report.get("input_surface", {})
    if input_surface and not input_surface.get("skipped"):
        print(f"- Input surface: {'ok' if input_surface.get('ok') else 'blocked'}")
        if input_surface.get("application_name"):
            print(f"- Screen frontmost app: {input_surface['application_name']}")
        if input_surface.get("window_title"):
            print(f"- Screen window title: {input_surface['window_title']}")
    capture = report.get("capture", {})
    if capture.get("skipped"):
        print("- Capture: skipped")
    else:
        print(f"- Capture: {'ok' if capture.get('ok') else 'failed'}")
        if capture.get("blocked_reason"):
            print(f"- Capture blocked reason: {capture['blocked_reason']}")
        if capture.get("screenshot_path"):
            print(f"- Screenshot: `{capture['screenshot_path']}` ({capture.get('screenshot_bytes', 0)} bytes)")
        pixel_summary = capture.get("pixel_summary") or {}
        if pixel_summary:
            print(f"- Screenshot nonblack: {'yes' if pixel_summary.get('nonblack') else 'no'}")
    if report.get("blocked_reason"):
        print(f"- Blocked reason: {report['blocked_reason']}")
    fallback = report.get("fallback") or {}
    if fallback.get("required"):
        print(f"- Fallback: {fallback.get('path')}")
    if report.get("remediation"):
        print("")
        print("Remediation:")
        for step in report["remediation"]:
            print(f"- {step}")


if __name__ == "__main__":
    sys.exit(main())
