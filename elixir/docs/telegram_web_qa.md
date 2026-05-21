# Telegram Web QA

Use this path when OpenClaw must validate a Telegram bot through Telegram Web on the Mac.
Workers must discover the available browser QA path before claiming Telegram Web, Peekaboo, or
Codex Computer Use is unavailable.

## Capability Probe

Run this first from the repository root:

```sh
python3 scripts/openclaw_browser_qa_capability_probe.py --json
```

The probe checks the repo CDP helper, Chrome DevTools, the approved Telegram QA profile/keychain
boundary, Peekaboo readiness, and whether Codex Computer Use must be checked in the worker tool
list. If direct QA is blocked, copy `expected_blocker_message` into the Kaneo workpad instead of
ending with a vague "Computer Use unavailable" note.

Supported path order:

1. Use `scripts/telegram_web_qa.mjs` when Chrome CDP is reachable and a logged-in Telegram Web
   target is visible.
2. Use Peekaboo when `scripts/openclaw_peekaboo_healthcheck.py --json` reports `ready: true`.
3. Use Codex Computer Use only when the worker prompt/tool list exposes `mcp__computer_use__.*`
   tools.
4. Escalate to a main-session QA helper with the structured blocker when none of the direct paths
   are ready.

## CDP Helper Path

Launch a dedicated Chrome QA profile with the Chrome DevTools Protocol enabled:

```sh
HOME=/Users/borodutch \
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/Library/Application Support/Symphony/telegram-web-qa-chrome" \
  "https://web.telegram.org/k/#@okamikron_bot"
```

OpenClaw/Codex sessions can have `HOME` set to an agent sandbox. Always launch Chrome with
`HOME=/Users/borodutch` for logged-in QA profiles so Chrome uses the real macOS login keychain and
does not show "A keychain cannot be found to store Chrome" prompts. For disposable profiles that do
not need existing encrypted cookies or extension state, adding `--use-mock-keychain` is acceptable.

The profile must be logged in to Telegram Web once before unattended QA. Keep it dedicated to QA so
remote debugging is not enabled on a personal browsing profile.

Run the helper from the repository root:

```sh
node scripts/telegram_web_qa.mjs \
  --browser-url http://127.0.0.1:9222 \
  --chat @okamikron_bot \
  --message "Voicy QA $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --send \
  --json
```

The helper opens or reuses a Telegram Web tab, navigates to the target chat, inserts the message into
the composer, sends it, and verifies the message text is present in the page. It prints JSON evidence
including the target chat, message text, active URL, and verification status.

For a read-only check, omit `--send` and provide `--verify-text`:

```sh
node scripts/telegram_web_qa.mjs \
  --browser-url http://127.0.0.1:9222 \
  --chat @okamikron_bot \
  --verify-text "Voicy QA 2026-05-01T00:00:00Z" \
  --json
```

## Failure Handling

- If Chrome is not reachable, relaunch it with the exact remote debugging flags above.
- If Telegram Web shows a login screen, the QA profile is not logged in; stop and record that as the
  blocker instead of trying to bypass login.
- If the helper cannot find the message composer, record the active URL and JSON error in the Kaneo
  workpad. This usually means Telegram Web changed its DOM or the chat did not open.
- If the CDP helper is unavailable or blocked, use the capability probe result to choose Peekaboo,
  Codex Computer Use, or main-session escalation. Keep AppleScript JavaScript execution and Chrome
  Apple Events out of the proof path.

## Kaneo Evidence

For Voicy end-to-end QA, record:

- browser URL, normally `http://127.0.0.1:9222`;
- target bot, normally `@okamikron_bot`;
- exact message text;
- helper JSON output showing `verified: true`;
- any screenshot or recording OpenClaw captures after verification.
