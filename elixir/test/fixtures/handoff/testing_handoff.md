### Testing Handoff

Automated validation run by Symphony:
- `cd elixir && mix test test/symphony_elixir/core_test.exs:1354` passed; rendered workflow prompt includes testing handoff requirements.
- `cd elixir && mix test test/symphony_elixir/core_test.exs` passed; prompt and workflow regression tests are green.

Manual QA for OpenClaw/humans:
- Required in Chrome against the Kaneo project board.
- Move a completed implementation task to `in-review`.
- Expected result: the Kaneo workpad or PR handoff contains automated validation evidence and this manual QA checklist.
- Evidence to attach: comment URL or screenshot showing the `Testing Handoff` section.

Manual QA: not required for prompt-only/doc changes when the automated prompt-rendering test is green.
