# Activity Stream Service

Symphony can expose a tiny realtime activity stream on the existing Phoenix HTTP
server. Trusted bots and project services submit already-anonymized display
strings, and browser clients watch a plain WebSocket feed with recent replay.

The service keeps records only in memory. It does not store a database copy, and
emitters must not send raw Telegram user, chat, or message content unless they
have already anonymized it at the source.

## Endpoints

- `GET /activity/v1/health`
  - Returns service status and active limits.
- `POST /activity/v1/events`
  - Accepts JSON or form payloads with `text` and optional `source` and
    `project`.
  - Requires `Authorization: Bearer <token>`. The `x-activity-token` and
    `x-symphony-activity-token` headers are also accepted for simple emitters.
  - Returns `202` with the generated event envelope.
- `GET /activity/v1/stream?replay=<count>`
  - Upgrades to a plain WebSocket.
  - Sends recent buffered events first, oldest first, then live events as they
    arrive.
  - Each frame is JSON: `{"type":"event","event":{...}}`.

Event envelopes include:

```json
{
  "id": "evt_...",
  "timestamp": "2026-05-13T18:00:00.000Z",
  "text": "Chat 1***34***54 sent a message",
  "source": "bot",
  "project": "voicy"
}
```

## Environment

- `SYMPHONY_ACTIVITY_TOKEN`
  - Required for `POST /activity/v1/events`.
  - Use a 35-character random value and keep it outside git.
- `SYMPHONY_ACTIVITY_CORS_ORIGIN`
  - Optional. Defaults to `*`.
  - Set to `https://borodutch.com` when only that browser origin should submit
    or subscribe.
- `SYMPHONY_ACTIVITY_MAX_EVENTS`
  - Optional. Defaults to `200` in-memory replay records.
- `SYMPHONY_ACTIVITY_MAX_TEXT_BYTES`
  - Optional. Defaults to `500` bytes.
- `SYMPHONY_ACTIVITY_RATE_LIMIT_WINDOW_MS`
  - Optional. Defaults to `1000`.
- `SYMPHONY_ACTIVITY_RATE_LIMIT_MAX_EVENTS`
  - Optional. Defaults to `20` events per remote IP per window.

Generate a 35-character token:

```bash
LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 35; echo
```

## Local Run

Run Symphony with the Phoenix server enabled:

```bash
cd elixir
export SYMPHONY_ACTIVITY_TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 35)"
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4057 ./WORKFLOW.md
```

Submit an event:

```bash
curl -i http://127.0.0.1:4057/activity/v1/events \
  -H "Authorization: Bearer $SYMPHONY_ACTIVITY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Chat 1***34***54 sent a message","project":"voicy","source":"bot"}'
```

Smoke test the HTTP and WebSocket path:

```bash
node scripts/activity_stream_smoke.mjs
```

The script starts a local Symphony server with an in-memory workflow, connects
multiple WebSocket clients, submits events, verifies replay, and checks the rate
limit.

## EasyPanel / Hetzner Notes

Deploy the existing Elixir app and expose the configured Symphony server port
through the EasyPanel service domain. Set these environment variables in
EasyPanel:

```text
SYMPHONY_ACTIVITY_TOKEN=<35-character random token>
SYMPHONY_ACTIVITY_CORS_ORIGIN=https://borodutch.com
SYMPHONY_ACTIVITY_MAX_EVENTS=200
SYMPHONY_ACTIVITY_MAX_TEXT_BYTES=500
SYMPHONY_ACTIVITY_RATE_LIMIT_WINDOW_MS=1000
SYMPHONY_ACTIVITY_RATE_LIMIT_MAX_EVENTS=20
```

Start command example:

```bash
./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4057 /app/WORKFLOW.md
```

Configure the public route to forward WebSocket upgrades as well as regular
HTTP requests. Verify after deployment:

```bash
curl -fsS https://activity.example.com/activity/v1/health
```

Then run a token-authenticated submit plus WebSocket smoke check from a trusted
environment. Do not print or commit the token in logs, docs, task comments, or
client-side code.
