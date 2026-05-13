#!/usr/bin/env node
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";

const repoRoot = resolve(new URL("..", import.meta.url).pathname);
const elixirDir = join(repoRoot, "elixir");
const port = Number(process.env.SYMPHONY_ACTIVITY_SMOKE_PORT || 4079);
const token = randomBytes(32).toString("base64url").slice(0, 35);
const tmp = await mkdtemp(join(tmpdir(), "symphony-activity-smoke-"));
const workflowPath = join(tmp, "WORKFLOW.md");

await writeFile(
  workflowPath,
  `---
tracker:
  kind: memory
server:
  host: "127.0.0.1"
  port: ${port}
---
Activity stream smoke workflow.
`,
);

const evalCode = [
  'Application.put_env(:symphony_elixir, :server_port_override, String.to_integer(System.fetch_env!("SYMPHONY_ACTIVITY_SMOKE_PORT")))',
  'SymphonyElixir.Workflow.set_workflow_file_path(System.fetch_env!("SYMPHONY_ACTIVITY_SMOKE_WORKFLOW"))',
  'Application.put_env(:symphony_elixir, :memory_tracker_issues, [])',
  "Application.ensure_all_started(:symphony_elixir)",
  "Process.sleep(:infinity)",
].join("; ");

const server = spawn("mise", ["exec", "--", "mix", "run", "--no-start", "-e", evalCode], {
  cwd: elixirDir,
  env: {
    ...process.env,
    SYMPHONY_ACTIVITY_TOKEN: token,
    SYMPHONY_ACTIVITY_RATE_LIMIT_WINDOW_MS: "30000",
    SYMPHONY_ACTIVITY_RATE_LIMIT_MAX_EVENTS: "2",
    SYMPHONY_ACTIVITY_SMOKE_PORT: String(port),
    SYMPHONY_ACTIVITY_SMOKE_WORKFLOW: workflowPath,
  },
  stdio: ["ignore", "pipe", "pipe"],
});

let serverOutput = "";
server.stdout.on("data", (chunk) => {
  serverOutput += chunk.toString();
});
server.stderr.on("data", (chunk) => {
  serverOutput += chunk.toString();
});

try {
  await waitForHealth(port);

  const firstClient = await openSocket(port);
  const secondClient = await openSocket(port);
  const firstMessage = nextMessage(firstClient);
  const secondMessage = nextMessage(secondClient);

  await submit(port, token, "Chat 1***34***54 sent a message", "borodutch", "bot");

  assertEvent(await firstMessage, "Chat 1***34***54 sent a message");
  assertEvent(await secondMessage, "Chat 1***34***54 sent a message");

  const replayClient = await openSocket(port);
  assertEvent(await nextMessage(replayClient), "Chat 1***34***54 sent a message");

  await submit(port, token, "Project deploy started", "infra", "deploy");
  const limited = await submit(port, token, "Project deploy finished", "infra", "deploy", false);
  if (limited.status !== 429) {
    throw new Error(`expected third submit to be rate limited, got ${limited.status}`);
  }

  firstClient.close();
  secondClient.close();
  replayClient.close();

  console.log("activity stream smoke passed: auth, live fanout, replay, and rate limit verified");
} finally {
  server.kill("SIGTERM");
  await rm(tmp, { recursive: true, force: true });
}

async function waitForHealth(portNumber) {
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${portNumber}/activity/v1/health`);
      if (response.ok) return;
    } catch {
      // service is still starting
    }
    await delay(250);
  }

  throw new Error(`activity stream server did not start on port ${portNumber}\n${serverOutput}`);
}

async function openSocket(portNumber) {
  const socket = new WebSocket(`ws://127.0.0.1:${portNumber}/activity/v1/stream?replay=10`);
  await new Promise((resolveOpen, rejectOpen) => {
    const timeout = setTimeout(() => rejectOpen(new Error("websocket open timeout")), 10000);
    socket.addEventListener("open", () => {
      clearTimeout(timeout);
      resolveOpen();
    }, { once: true });
    socket.addEventListener("error", (error) => {
      clearTimeout(timeout);
      rejectOpen(error);
    }, { once: true });
  });
  return socket;
}

async function nextMessage(socket) {
  return new Promise((resolveMessage, rejectMessage) => {
    const timeout = setTimeout(() => rejectMessage(new Error("websocket message timeout")), 10000);
    socket.addEventListener("message", (event) => {
      clearTimeout(timeout);
      resolveMessage(event.data);
    }, { once: true });
    socket.addEventListener("error", (error) => {
      clearTimeout(timeout);
      rejectMessage(error);
    }, { once: true });
  });
}

async function submit(portNumber, activityToken, text, project, source, expectAccepted = true) {
  const response = await fetch(`http://127.0.0.1:${portNumber}/activity/v1/events`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${activityToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ text, project, source }),
  });

  if (expectAccepted && response.status !== 202) {
    throw new Error(`submit failed with ${response.status}: ${await response.text()}`);
  }

  return response;
}

function assertEvent(raw, expectedText) {
  const parsed = JSON.parse(raw);
  if (parsed.type !== "event" || parsed.event?.text !== expectedText) {
    throw new Error(`unexpected websocket payload: ${raw}`);
  }
}

function delay(ms) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}
