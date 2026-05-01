#!/usr/bin/env node

import {setTimeout as delay} from "node:timers/promises";

const DEFAULT_BROWSER_URL = "http://127.0.0.1:9222";
const DEFAULT_CHAT = "@okamikron_bot";
const DEFAULT_TIMEOUT_MS = 30_000;

function usage() {
  return `Usage: node scripts/telegram_web_qa.mjs [options]

Options:
  --browser-url <url>   Chrome DevTools HTTP URL (default: ${DEFAULT_BROWSER_URL})
  --chat <handle>       Telegram chat handle or web.telegram.org URL (default: ${DEFAULT_CHAT})
  --message <text>      Text to send when --send is present
  --verify-text <text>  Text to verify without sending; defaults to --message
  --send                Send --message before verification
  --timeout-ms <ms>     Wait timeout for Telegram Web UI (default: ${DEFAULT_TIMEOUT_MS})
  --json                Print compact JSON only
  --help                Show this help
`;
}

function parseArgs(argv) {
  const opts = {
    browserUrl: DEFAULT_BROWSER_URL,
    chat: DEFAULT_CHAT,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    send: false,
    json: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--browser-url":
        opts.browserUrl = requireValue(argv, ++index, arg);
        break;
      case "--chat":
        opts.chat = requireValue(argv, ++index, arg);
        break;
      case "--message":
        opts.message = requireValue(argv, ++index, arg);
        break;
      case "--verify-text":
        opts.verifyText = requireValue(argv, ++index, arg);
        break;
      case "--timeout-ms":
        opts.timeoutMs = Number.parseInt(requireValue(argv, ++index, arg), 10);
        break;
      case "--send":
        opts.send = true;
        break;
      case "--json":
        opts.json = true;
        break;
      case "--help":
        opts.help = true;
        break;
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }

  if (opts.help) {
    return opts;
  }

  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) {
    throw new Error("--timeout-ms must be a positive integer");
  }

  if (opts.send && !opts.message) {
    throw new Error("--send requires --message");
  }

  opts.verifyText = opts.verifyText || opts.message;

  if (!opts.send && !opts.verifyText) {
    throw new Error("provide --send --message or --verify-text for verification");
  }

  return opts;
}

function requireValue(argv, index, option) {
  const value = argv[index];

  if (!value || value.startsWith("--")) {
    throw new Error(`${option} requires a value`);
  }

  return value;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.help) {
    process.stdout.write(usage());
    return;
  }

  if (typeof WebSocket !== "function") {
    throw new Error("this helper requires a Node.js runtime with global WebSocket support");
  }

  const client = new CdpClient(opts.browserUrl);
  const target = await client.telegramTarget(opts.chat);
  const session = await CdpSession.connect(target.webSocketDebuggerUrl);

  try {
    await session.call("Runtime.enable");
    await session.call("Page.enable");

    const result = await session.evaluate(telegramAutomationSource(), {
      chat: opts.chat,
      message: opts.message || "",
      verifyText: opts.verifyText,
      send: opts.send,
      timeoutMs: opts.timeoutMs
    });

    const output = {
      ok: true,
      browserUrl: opts.browserUrl,
      targetId: target.id,
      chat: opts.chat,
      sent: result.sent,
      verified: result.verified,
      message: result.message,
      url: result.url,
      title: result.title
    };

    printOutput(output, opts.json);
  } finally {
    session.close();
  }
}

function printOutput(output, jsonOnly) {
  if (jsonOnly) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
    return;
  }

  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

class CdpClient {
  constructor(browserUrl) {
    this.browserUrl = browserUrl.replace(/\/+$/, "");
  }

  async telegramTarget(chat) {
    const existing = await this.findTelegramTarget();

    if (existing) {
      return existing;
    }

    await this.openTelegramTarget(chat);

    const deadline = Date.now() + 10_000;

    while (Date.now() < deadline) {
      const target = await this.findTelegramTarget();

      if (target) {
        return target;
      }

      await delay(250);
    }

    throw new Error("Chrome DevTools did not expose a Telegram Web target");
  }

  async findTelegramTarget() {
    const targets = await this.getJson("/json/list");

    return targets.find((target) => {
      return target.type === "page" && target.url && target.url.includes("web.telegram.org");
    });
  }

  async openTelegramTarget(chat) {
    const url = telegramUrl(chat);
    const encodedUrl = encodeURIComponent(url);
    const response = await fetch(`${this.browserUrl}/json/new?${encodedUrl}`, {method: "PUT"});

    if (!response.ok) {
      throw new Error(`failed to open Telegram Web tab: HTTP ${response.status}`);
    }
  }

  async getJson(path) {
    const response = await fetch(`${this.browserUrl}${path}`);

    if (!response.ok) {
      throw new Error(`Chrome DevTools request failed for ${path}: HTTP ${response.status}`);
    }

    return response.json();
  }
}

class CdpSession {
  static connect(webSocketUrl) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(webSocketUrl);
      const session = new CdpSession(socket);

      socket.addEventListener("open", () => resolve(session), {once: true});
      socket.addEventListener("error", () => reject(new Error("failed to connect to Chrome DevTools WebSocket")), {
        once: true
      });
    });
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();

    socket.addEventListener("message", (event) => this.onMessage(event));
    socket.addEventListener("close", () => this.rejectPending(new Error("Chrome DevTools WebSocket closed")));
  }

  call(method, params = {}) {
    const id = this.nextId++;
    const payload = {id, method, params};

    return new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject});
      this.socket.send(JSON.stringify(payload));
    });
  }

  async evaluate(source, arg) {
    const expression = `(${source})(${JSON.stringify(arg)})`;

    const response = await this.call("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true
    });

    if (response.exceptionDetails) {
      const detail = response.exceptionDetails.exception?.description || response.exceptionDetails.text;
      throw new Error(`Telegram Web automation failed: ${detail}`);
    }

    return response.result.value;
  }

  close() {
    this.socket.close();
  }

  onMessage(event) {
    const message = JSON.parse(event.data);

    if (!message.id) {
      return;
    }

    const pending = this.pending.get(message.id);

    if (!pending) {
      return;
    }

    this.pending.delete(message.id);

    if (message.error) {
      pending.reject(new Error(`${message.error.message}: ${message.error.data || ""}`.trim()));
    } else {
      pending.resolve(message.result || {});
    }
  }

  rejectPending(error) {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }

    this.pending.clear();
  }
}

function telegramUrl(chat) {
  if (/^https:\/\/web\.telegram\.org\//.test(chat)) {
    return chat;
  }

  const normalized = chat.startsWith("@") ? chat : `@${chat}`;
  return `https://web.telegram.org/k/#${encodeURIComponent(normalized)}`;
}

function telegramAutomationSource() {
  return String.raw`
async function telegramAutomation({chat, message, verifyText, send, timeoutMs}) {
  const startedAt = Date.now();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const deadlineReached = () => Date.now() - startedAt > timeoutMs;
  const normalizedChat = chat.startsWith("@") ? chat : "@" + chat;
  const visible = (element) => {
    if (!element) return false;
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  };

  const targetUrl = chat.startsWith("https://web.telegram.org/")
    ? chat
    : "https://web.telegram.org/k/#" + encodeURIComponent(normalizedChat);

  if (!location.href.includes("web.telegram.org")) {
    location.href = targetUrl;
  } else if (location.href !== targetUrl && normalizedChat.includes("@")) {
    location.href = targetUrl;
  }

  await waitForAuthenticatedUi();
  await openChatFromSearch(normalizedChat);
  await clickStartIfPresent();

  let composer = findComposer();

  if (!composer) {
    await waitFor(() => Boolean(findComposer()), "Telegram Web message composer");
    composer = findComposer();
  }

  if (!composer) {
    throw new Error("Telegram Web message composer was not found");
  }

  let sent = false;

  if (send) {
    composer.focus();

    if (composer.isContentEditable) {
      document.execCommand("selectAll", false, null);
      document.execCommand("insertText", false, message);
      composer.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertText", data: message}));
    } else {
      composer.textContent = message;
      composer.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertText", data: message}));
    }

    await waitFor(() => (document.body?.innerText || "").includes(message), "message text to appear in composer");

    const button = findSendButton();

    if (button) {
      button.click();
    } else {
      composer.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "Enter",
          code: "Enter",
          keyCode: 13,
          which: 13,
          bubbles: true,
          cancelable: true
        })
      );
    }

    sent = true;
  }

  if (verifyText) {
    await waitFor(() => (document.body?.innerText || "").includes(verifyText), "sent or existing message text");
  }

  return {
    sent,
    verified: Boolean(verifyText && (document.body?.innerText || "").includes(verifyText)),
    message: verifyText || message,
    url: location.href,
    title: document.title
  };

  async function waitFor(predicate, label) {
    while (!deadlineReached()) {
      if (predicate()) {
        return;
      }

      await sleep(250);
    }

    throw new Error("Timed out waiting for " + label);
  }

  async function waitForAuthenticatedUi() {
    await waitFor(() => {
      const bodyText = document.body?.innerText || "";

      if (/Log in to Telegram|Scan QR code|Please choose your country|phone number/i.test(bodyText)) {
        throw new Error("Telegram Web profile is not logged in");
      }

      return Boolean(document.querySelector('input.input-search-input') || findComposer());
    }, "Telegram Web authenticated UI");
  }

  async function openChatFromSearch(targetHandle) {
    if (location.href.includes(encodeURIComponent(targetHandle)) || location.href.includes(targetHandle)) {
      return;
    }

    const searchInput = document.querySelector('input.input-search-input');

    if (!visible(searchInput)) {
      return;
    }

    searchInput.focus();
    searchInput.click();
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;

    if (setter) {
      setter.call(searchInput, targetHandle);
    } else {
      searchInput.value = targetHandle;
    }

    searchInput.dispatchEvent(new Event('input', {bubbles: true}));
    await sleep(750);

    const target = Array.from(document.querySelectorAll('a')).find((anchor) => {
      return visible(anchor) && (anchor.innerText || anchor.textContent || '').includes(targetHandle);
    });

    if (!target) {
      return;
    }

    for (const type of ['mouseover', 'mousedown', 'mouseup', 'click']) {
      target.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, view: window, button: 0, buttons: 1}));
    }

    await sleep(1500);
  }

  async function clickStartIfPresent() {
    const startButton = Array.from(document.querySelectorAll('button')).find((button) => {
      return visible(button) && /^START$/i.test((button.innerText || button.textContent || '').trim());
    });

    if (!startButton) {
      return;
    }

    startButton.click();
    await sleep(1500);
  }

  function findComposer() {
    const selectors = ['.input-message-input', '[contenteditable="true"]', 'textarea'];
    const candidates = selectors.flatMap((selector) => Array.from(document.querySelectorAll(selector)));

    return candidates.find((element) => {
      if (!visible(element)) return false;
      const label = [
        element.getAttribute("aria-label"),
        element.getAttribute("data-placeholder"),
        element.getAttribute("placeholder"),
        element.textContent,
        element.className
      ].join(" ");

      return /message|write|input|composer|editable/i.test(label) || candidates.length === 1;
    });
  }

  function findSendButton() {
    const selectors = [
      'button[aria-label*="Send" i]',
      'button[title*="Send" i]',
      '.btn-send',
      '.send'
    ];

    for (const selector of selectors) {
      const button = Array.from(document.querySelectorAll(selector)).find(visible);

      if (button) {
        return button;
      }
    }

    return Array.from(document.querySelectorAll("button")).find((button) => {
      return visible(button) && /send/i.test(button.getAttribute("aria-label") || button.title || button.textContent || "");
    });
  }
}
`;
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
