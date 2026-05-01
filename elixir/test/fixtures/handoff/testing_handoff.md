### Testing Handoff

Automated validation run by Symphony:
- `cd elixir && mix test test/symphony_elixir/core_test.exs:1354` passed; rendered workflow prompt includes testing handoff requirements.
- `cd elixir && mix test test/symphony_elixir/core_test.exs` passed; prompt and workflow regression tests are green.

Manual QA for OpenClaw/humans:
- Required in Chrome against the Kaneo project board only when the change modifies task transition or handoff UI behavior.
- Path: move a completed implementation task to `in-review`.
- Expected result: the Kaneo workpad or PR handoff contains automated validation evidence and bounded review guidance.
- Evidence to attach: comment URL or screenshot showing the `Testing Handoff` section.
- Unknowns: no browser, Telegram, mobile, or device-specific QA path is implied by prompt-only changes; OpenClaw should choose one only if the changed surface area requires it.

Review guidance:
- Check that the handoff separates commands Symphony actually ran from manual QA still needed.
- Do not add unrelated manual testing steps that are not supported by the task context.

Manual QA: not required for prompt-only/doc changes when the automated prompt-rendering test is green.
