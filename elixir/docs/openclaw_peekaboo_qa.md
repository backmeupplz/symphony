# OpenClaw Peekaboo QA

Peekaboo is the primary UI automation path for OpenClaw browser, macOS UI, and Telegram Web QA.

## Healthcheck

Run the repo-local doctor-equivalent check before UI QA:

```sh
python3 scripts/openclaw_peekaboo_healthcheck.py
```

It verifies:

- `peekaboo` is available on `PATH`.
- console user and display activity diagnostics are visible.
- the selected Peekaboo Bridge host/socket and runtime permissions.
- required Screen Recording and Accessibility permissions are granted from the active OpenClaw/Peekaboo runtime.
- Chrome is visible to Peekaboo.
- a real Chrome screenshot can be captured and written as a non-empty PNG.
- the active screen is an input-safe desktop, not the macOS login window.

For machine-readable output:

```sh
python3 scripts/openclaw_peekaboo_healthcheck.py --json
```

If permissions are blocked, grant the missing item to the OpenClaw/Peekaboo runtime in System Settings > Privacy & Security, then restart the OpenClaw bridge/runtime before retrying.

If the healthcheck reports `loginwindow`, unlock the macOS user session before Chrome or Telegram Web QA. Screen Recording can be granted and Chrome window capture can sometimes work while the GUI is still unsafe for clicks or typing.

## Worker Capability Probe

Every OpenClaw/Symphony worker must run the browser QA capability probe before claiming browser,
Telegram Web, Peekaboo, or Codex Computer Use is unavailable:

```sh
python3 scripts/openclaw_browser_qa_capability_probe.py --json
```

The probe reports:

- the available repo Telegram Web CDP helper, if the current checkout has one.
- Chrome DevTools reachability at `http://127.0.0.1:9222` and whether a Telegram Web target is open.
- the approved logged-in Telegram QA Chrome profile and keychain boundary.
- Peekaboo bridge, permissions, Chrome visibility, capture, and input-surface readiness.
- Codex Computer Use exposure status. Computer Use is not shell-probeable; it is available only when the worker prompt/tool list exposes `mcp__computer_use__.*` tools.
- the exact supported QA path, remediation, and a ready-to-paste blocker message when direct QA is blocked.

Use this result order:

1. If the repo provides `scripts/telegram_web_qa.mjs` and Chrome CDP has a logged-in Telegram Web target, use the repo helper.
2. If Peekaboo is ready, use the Peekaboo smoke helper or manual Peekaboo UI flow.
3. If the worker has `mcp__computer_use__.*` tools, use Codex Computer Use and attach screenshot/evidence.
4. If none are ready, paste `expected_blocker_message` into the Kaneo workpad and route the task to a main-session QA helper. Do not stop at "Computer Use unavailable" without the probe result.

For logged-in Chrome profiles, launch with `HOME=/Users/borodutch` so Chrome uses the real macOS login keychain. Use `--use-mock-keychain` only for disposable throwaway profiles. Keep all browser inspection scoped to the approved Telegram/browser QA task; do not inspect, export, or copy private profile data or credentials.

## Telegram Web QA Policy

- Use Peekaboo with Chrome/Telegram Web and a logged-in real Telegram account for Telegram bot UX proof.
- Do not validate bot UX by trying to make one Telegram bot message another bot. Telegram bots cannot initiate chats with other bots.
- Keep Codex Computer Use as the escalation path when Peekaboo is blocked or inadequate.
- Keep CDP, AppleScript, and DOM scripting as narrow diagnostics only.

Minimal smoke flow:

Run the scripted smoke helper:

```sh
python3 scripts/openclaw_peekaboo_telegram_smoke.py --json
```

It runs the healthcheck, opens `@okamikron_bot` in Telegram Web, sends a timestamped message with Peekaboo click/type commands, captures before/after screenshots under `tmp/`, and writes a full JSON report under `tmp/`.

To wait briefly for an unlock before failing:

```sh
python3 scripts/openclaw_peekaboo_telegram_smoke.py --wait-ready-seconds 300 --json
```

If Telegram Web is visible but Chrome exposes no message input through accessibility, pass a reviewed screenshot coordinate for the composer. Coordinates must be non-negative integers in `x,y` form:

```sh
python3 scripts/openclaw_peekaboo_telegram_smoke.py --wait-ready-seconds 300 --input-coords 932,904 --json
```

Interpret the JSON result this way:

- `ok: true` means the message was sent and the exact timestamped text was found in Peekaboo's post-send UI JSON.
- `blocked: healthcheck_failed` with `screen_probe.application_name: loginwindow`, `input_surface.application_name: loginwindow`, or `healthcheck_attempts[].input_surface_app: loginwindow` means macOS is locked or showing the login window; unlock the console user and rerun the same command.
- `blocked: telegram_window_capture_failed` means Telegram Web or Chrome is not capturable even after the healthcheck passed; inspect the `capture_before` step and screenshot path.
- `blocked: message_input_not_found` means the Telegram Web chat opened but Peekaboo could not focus the message field; rerun with `--input-query` set to the visible placeholder text or a reviewed `--input-coords x,y` value from the before screenshot.
- `blocked: message_not_verified_in_peekaboo_ui_json` means Peekaboo sent or attempted the message but did not find the exact text in UI JSON; use the after screenshot as the visual verification artifact if it clearly shows the sent message.

Manual equivalent:

1. Run `python3 scripts/openclaw_peekaboo_healthcheck.py`.
2. Open Telegram Web in Chrome with the dedicated logged-in QA profile.
3. Use Peekaboo to inspect the Chrome window:

   ```sh
   peekaboo see --app "Google Chrome" --path /tmp/telegram-web.png --json
   ```

4. Navigate to `@okamikron_bot`.
5. Send a timestamped message from the real account.
6. Verify the sent text is visible in Telegram Web and record the message text plus screenshot path in the Kaneo workpad.

When a repo provides a Telegram Web CDP helper, prefer that helper for deterministic send/verify proof. Use Peekaboo for visual inspection and manual UI control when the helper is unavailable or blocked.
