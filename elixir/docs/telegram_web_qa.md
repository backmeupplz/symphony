# Telegram Web QA

Use this path when OpenClaw must validate a Telegram bot through Telegram Web on the Mac. It avoids
Peekaboo screenshots, AppleScript JavaScript execution, and Chrome's disabled "Allow JavaScript from
Apple Events" setting.

## Supported Path

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
- Do not fall back to Peekaboo, AppleScript JavaScript execution, or Chrome Apple Events for Telegram
  Web QA.

## Kaneo Evidence

For Voicy end-to-end QA, record:

- browser URL, normally `http://127.0.0.1:9222`;
- target bot, normally `@okamikron_bot`;
- exact message text;
- helper JSON output showing `verified: true`;
- any screenshot or recording OpenClaw captures after verification.
