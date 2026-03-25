import * as http from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import { resolveWorktoolAccount } from "./channel.js";
import { handleInboundWebhook, normalizeInboundWebhook } from "./inbound.js";
import { getWorktoolRuntime } from "./runtime.js";

const servers = new Map();
const MAX_BODY_BYTES = 1024 * 1024;
const BODY_TIMEOUT_MS = 30_000;

function isJsonContentType(value) {
  const first = Array.isArray(value) ? value[0] : value;
  if (!first) return false;
  const mediaType = first.split(";", 1)[0]?.trim().toLowerCase();
  return mediaType === "application/json" || Boolean(mediaType?.endsWith("+json"));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;

    const timer = setTimeout(() => {
      reject(new Error("request body timeout"));
    }, BODY_TIMEOUT_MS);

    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        clearTimeout(timer);
        reject(new Error("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      clearTimeout(timer);
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (!raw) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("invalid JSON body"));
      }
    });

    req.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function sendJson(res, status, data) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(data));
}

function sendHtml(res, status, html) {
  res.statusCode = status;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.end(html);
}

function normalizePath(req) {
  const url = req.url || "/";
  return new URL(url, "http://localhost").pathname;
}

function readQueryRobotId(req) {
  const url = req.url || "/";
  return new URL(url, "http://localhost").searchParams.get("robotId")?.trim() || "";
}

function readQueryToken(req) {
  const url = req.url || "/";
  return new URL(url, "http://localhost").searchParams.get("token")?.trim() || "";
}

function readHeaderToken(req) {
  return String(req.headers["x-worktool-token"] || "").trim();
}

function isTokenAuthorized(req, account) {
  const headerToken = readHeaderToken(req);
  const queryRobotId = readQueryRobotId(req);
  const queryToken = readQueryToken(req);
  const providedToken = headerToken || queryRobotId || queryToken;
  if (account.webhookToken) {
    return providedToken.length > 0 && providedToken === account.webhookToken;
  }
  if (account.robotId) {
    return providedToken.length > 0 && providedToken === account.robotId;
  }
  return true;
}

function deriveAdminPath(webhookPath) {
  const p = webhookPath || "/wechat/webhook";
  if (p.endsWith("/webhook")) return `${p.slice(0, -"/webhook".length)}/admin`;
  return `${p.replace(/\/+$/, "")}/admin`;
}

function resolveOpenclawConfigPath() {
  const fromEnv = String(process.env.OPENCLAW_CONFIG || "").trim();
  if (fromEnv) return fromEnv;
  const home = String(process.env.HOME || "").trim();
  if (!home) return ".openclaw/openclaw.json";
  return `${home}/.openclaw/openclaw.json`;
}

function buildAdminHtml(params) {
  const { accountId, webhookPath, adminPath, account } = params;
  const state = {
    accountId,
    robotId: account.robotId || "",
    bridgeBaseUrl: account.bridgeBaseUrl || "",
    webhookToken: account.webhookToken || "",
    webhookHost: account.webhookHost || "0.0.0.0",
    webhookPort: account.webhookPort || 18799,
    webhookPath: account.webhookPath || webhookPath,
    adminPath,
  };
  const encoded = Buffer.from(JSON.stringify(state), "utf8").toString("base64");
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>WorkTool Admin</title>
  <style>
    body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;padding:20px;max-width:860px;margin:0 auto;background:#f8fafc;color:#0f172a}
    h1{font-size:22px;margin:0 0 12px}
    .muted{color:#475569;font-size:13px}
    .card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:14px;margin:14px 0}
    label{display:block;font-size:13px;color:#334155;margin:10px 0 4px}
    input,textarea{width:100%;box-sizing:border-box;border:1px solid #cbd5e1;border-radius:8px;padding:10px;font-size:14px}
    textarea{min-height:120px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    .row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    .btns{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
    button{border:0;background:#0f766e;color:#fff;padding:10px 14px;border-radius:8px;cursor:pointer}
    button.secondary{background:#334155}
    pre{background:#0f172a;color:#e2e8f0;padding:10px;border-radius:8px;overflow:auto}
  </style>
</head>
<body>
  <h1>WorkTool Admin</h1>
  <div class="muted">用于快速修改 WorkTool 渠道关键参数并执行回调自测。访问时需在 URL 带上 <code>?robotId=xxx</code> 或 <code>?token=xxx</code>。</div>

  <div class="card">
    <div><b>Account</b>: <span id="accountId"></span></div>
    <label>robotId</label><input id="robotId" />
    <label>bridgeBaseUrl</label><input id="bridgeBaseUrl" />
    <label>webhookToken (可选，配置后优先鉴权)</label><input id="webhookToken" />
    <div class="row">
      <div><label>webhookHost</label><input id="webhookHost" /></div>
      <div><label>webhookPort</label><input id="webhookPort" /></div>
    </div>
    <label>webhookPath</label><input id="webhookPath" />
    <div class="btns">
      <button id="btnSave">保存配置</button>
      <button id="btnReload" class="secondary">刷新状态</button>
    </div>
    <p class="muted">说明：host/port 变更需要重启 OpenClaw；path/robotId/bridgeBaseUrl 可立即用于后续请求。</p>
  </div>

  <div class="card">
    <label>回调测试 Payload (POST 到 webhook)</label>
    <textarea id="payload"></textarea>
    <div class="btns">
      <button id="btnTest">发送测试回调</button>
    </div>
    <pre id="output"></pre>
  </div>

  <script>
    const seed = JSON.parse(atob("${encoded}"));
    const q = new URLSearchParams(location.search);
    let authToken = q.get("token") || q.get("robotId") || seed.robotId || "";
    const apiBase = seed.adminPath + "/api";
    const output = document.getElementById("output");
    const defaultPayload = {
      spoken: "admin测试",
      rawSpoken: "@me admin测试",
      receivedName: "tester",
      groupName: "test-group",
      groupRemark: "",
      roomType: "1",
      atMe: true,
      textType: "1",
      fileBase64: ""
    };
    function qs() {
      if (!authToken) return "";
      return "?token=" + encodeURIComponent(authToken);
    }
    function fill(v) {
      document.getElementById("accountId").textContent = v.accountId || seed.accountId;
      document.getElementById("robotId").value = v.robotId || "";
      document.getElementById("bridgeBaseUrl").value = v.bridgeBaseUrl || "";
      document.getElementById("webhookToken").value = v.webhookToken || "";
      document.getElementById("webhookHost").value = v.webhookHost || "0.0.0.0";
      document.getElementById("webhookPort").value = String(v.webhookPort || 18799);
      document.getElementById("webhookPath").value = v.webhookPath || "";
    }
    async function refresh() {
      const r = await fetch(apiBase + "/state" + qs());
      const j = await r.json();
      if (!r.ok) throw new Error(JSON.stringify(j));
      fill(j);
      output.textContent = JSON.stringify(j, null, 2);
    }
    async function save() {
      const body = {
        robotId: document.getElementById("robotId").value.trim(),
        bridgeBaseUrl: document.getElementById("bridgeBaseUrl").value.trim(),
        webhookToken: document.getElementById("webhookToken").value.trim(),
        webhookHost: document.getElementById("webhookHost").value.trim(),
        webhookPort: Number(document.getElementById("webhookPort").value || 18799),
        webhookPath: document.getElementById("webhookPath").value.trim()
      };
      const r = await fetch(apiBase + "/save" + qs(), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const j = await r.json();
      if (!r.ok) throw new Error(JSON.stringify(j));
      authToken = body.webhookToken || body.robotId || authToken;
      output.textContent = JSON.stringify(j, null, 2);
    }
    async function test() {
      const payload = JSON.parse(document.getElementById("payload").value || "{}");
      const r = await fetch(apiBase + "/test" + qs(), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
      const j = await r.json();
      output.textContent = JSON.stringify(j, null, 2);
    }
    document.getElementById("btnSave").onclick = () => save().catch((e) => output.textContent = String(e));
    document.getElementById("btnReload").onclick = () => refresh().catch((e) => output.textContent = String(e));
    document.getElementById("btnTest").onclick = () => test().catch((e) => output.textContent = String(e));
    document.getElementById("payload").value = JSON.stringify(defaultPayload, null, 2);
    fill(seed);
    refresh().catch((e) => output.textContent = String(e));
  </script>
</body>
</html>`;
}

async function persistWorktoolConfig(params) {
  const configPath = resolveOpenclawConfigPath();
  const raw = await readFile(configPath, "utf8");
  const cfg = JSON.parse(raw);
  cfg.channels = cfg.channels || {};
  cfg.channels.worktool = cfg.channels.worktool || {};
  const section = cfg.channels.worktool;
  const isDefault = params.accountId === "default";
  let target;
  if (isDefault) {
    target = section;
  } else {
    section.accounts = section.accounts || {};
    section.accounts[params.accountId] = section.accounts[params.accountId] || {};
    target = section.accounts[params.accountId];
  }
  for (const [key, value] of Object.entries(params.patch)) {
    if (value === undefined) continue;
    if (typeof value === "string") {
      target[key] = value.trim();
      continue;
    }
    target[key] = value;
  }
  target.enabled = true;
  await writeFile(configPath, JSON.stringify(cfg, null, 2));
  return configPath;
}

async function monitorSingleAccount(params) {
  const { cfg, accountId, runtime, abortSignal } = params;
  let account = resolveWorktoolAccount(cfg, accountId);
  const host = account.webhookHost || "0.0.0.0";
  const port = Number(account.webhookPort || 18799);
  let webhookPath = account.webhookPath || "/wechat/webhook";
  let adminPath = deriveAdminPath(webhookPath);

  const log = runtime?.log ?? console.log;
  const error = runtime?.error ?? console.error;

  const server = http.createServer(async (req, res) => {
    const reqPath = normalizePath(req);

    const adminStatePath = `${adminPath}/api/state`;
    const adminSavePath = `${adminPath}/api/save`;
    const adminTestPath = `${adminPath}/api/test`;

    if (reqPath === adminPath && req.method === "GET") {
      if (!isTokenAuthorized(req, account)) {
        sendJson(res, 401, { ok: false, error: "unauthorized" });
        return;
      }
      sendHtml(res, 200, buildAdminHtml({ accountId, webhookPath, adminPath, account }));
      return;
    }

    if (reqPath === adminStatePath && req.method === "GET") {
      if (!isTokenAuthorized(req, account)) {
        sendJson(res, 401, { ok: false, error: "unauthorized" });
        return;
      }
      sendJson(res, 200, {
        ok: true,
        accountId,
        robotId: account.robotId || "",
        bridgeBaseUrl: account.bridgeBaseUrl || "",
        webhookToken: account.webhookToken || "",
        webhookHost: account.webhookHost || "0.0.0.0",
        webhookPort: account.webhookPort || 18799,
        webhookPath,
        adminPath,
      });
      return;
    }

    if (reqPath === adminSavePath && req.method === "POST") {
      if (!isTokenAuthorized(req, account)) {
        sendJson(res, 401, { ok: false, error: "unauthorized" });
        return;
      }
      if (!isJsonContentType(req.headers["content-type"])) {
        sendJson(res, 415, { ok: false, error: "content-type must be application/json" });
        return;
      }
      try {
        const body = await readJsonBody(req);
        const nextRobotId = String(body.robotId || account.robotId || "").trim();
        if (!nextRobotId) {
          sendJson(res, 400, { ok: false, error: "robotId is required" });
          return;
        }
        const nextBridge = String(body.bridgeBaseUrl || account.bridgeBaseUrl || "").trim();
        if (!nextBridge) {
          sendJson(res, 400, { ok: false, error: "bridgeBaseUrl is required" });
          return;
        }
        const nextWebhookPath = String(body.webhookPath || webhookPath || "").trim() || webhookPath;
        const nextWebhookHost = String(body.webhookHost || account.webhookHost || host).trim() || host;
        const nextWebhookPort = Number(body.webhookPort || account.webhookPort || port);
        const nextWebhookToken = String(body.webhookToken || "").trim();

        const configPath = await persistWorktoolConfig({
          accountId,
          patch: {
            robotId: nextRobotId,
            bridgeBaseUrl: nextBridge,
            webhookToken: nextWebhookToken,
            webhookHost: nextWebhookHost,
            webhookPort: nextWebhookPort,
            webhookPath: nextWebhookPath,
          },
        });

        account = {
          ...account,
          robotId: nextRobotId,
          bridgeBaseUrl: nextBridge,
          webhookToken: nextWebhookToken,
          webhookHost: nextWebhookHost,
          webhookPort: nextWebhookPort,
          webhookPath: nextWebhookPath,
        };
        webhookPath = nextWebhookPath;
        adminPath = deriveAdminPath(webhookPath);

        sendJson(res, 200, {
          ok: true,
          saved: true,
          restartRequired: nextWebhookHost !== host || nextWebhookPort !== port,
          configPath,
          accountId,
          robotId: nextRobotId,
          bridgeBaseUrl: nextBridge,
          webhookPath: nextWebhookPath,
          adminPath,
        });
      } catch (err) {
        sendJson(res, 400, { ok: false, error: String(err) });
      }
      return;
    }

    if (reqPath === adminTestPath && req.method === "POST") {
      if (!isTokenAuthorized(req, account)) {
        sendJson(res, 401, { ok: false, error: "unauthorized" });
        return;
      }
      if (!isJsonContentType(req.headers["content-type"])) {
        sendJson(res, 415, { ok: false, error: "content-type must be application/json" });
        return;
      }
      try {
        const payload = await readJsonBody(req);
        const normalized = normalizeInboundWebhook(payload);
        if (!normalized) {
          sendJson(res, 400, { ok: false, error: "invalid test payload" });
          return;
        }
        sendJson(res, 200, { ok: true, queued: true, messageId: normalized.messageId });
        void handleInboundWebhook({ cfg, payload, accountId, runtime }).catch((err) =>
          error(`worktool[${accountId}]: async admin test error: ${String(err)}`),
        );
      } catch (err) {
        sendJson(res, 400, { ok: false, error: String(err) });
      }
      return;
    }

    if (reqPath !== webhookPath) {
      sendJson(res, 404, { ok: false, error: "not found" });
      return;
    }

    if (req.method === "GET") {
      sendJson(res, 200, {
        ok: true,
        channel: "worktool",
        path: webhookPath,
        adminPath,
        accountId,
      });
      return;
    }

    if (req.method !== "POST") {
      sendJson(res, 405, { ok: false, error: "method not allowed" });
      return;
    }

    if (!isTokenAuthorized(req, account)) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    if (!isJsonContentType(req.headers["content-type"])) {
      sendJson(res, 415, { ok: false, error: "content-type must be application/json" });
      return;
    }

    try {
      const payload = await readJsonBody(req);
      const normalized = normalizeInboundWebhook(payload);
      if (!normalized) {
        throw new Error("unsupported inbound payload: cannot extract text/sender/chat fields");
      }
      let sessionKey = null;
      try {
        const core = getWorktoolRuntime();
        const route = core.channel.routing.resolveAgentRoute({
          cfg,
          channel: "worktool",
          accountId: account.accountId,
          peer: {
            kind: normalized.chatType === "group" ? "group" : "direct",
            id: normalized.chatType === "group" ? normalized.chatId : normalized.senderId,
          },
        });
        sessionKey = route.sessionKey ?? null;
      } catch {
        sessionKey = null;
      }

      sendJson(res, 200, {
        ok: true,
        accepted: true,
        queued: true,
        duplicate: false,
        messageId: normalized.messageId,
        sessionKey,
      });

      void handleInboundWebhook({ cfg, payload, accountId, runtime }).catch((err) => {
        error(`worktool[${accountId}]: async inbound processing error: ${String(err)}`);
      });
    } catch (err) {
      error(`worktool[${accountId}]: inbound webhook error: ${String(err)}`);
      sendJson(res, 400, {
        ok: false,
        error: String(err),
      });
    }
  });

  servers.set(accountId, server);

  await new Promise((resolve, reject) => {
    const cleanup = () => {
      server.close();
      servers.delete(accountId);
    };

    const handleAbort = () => {
      log(`worktool[${accountId}]: abort signal received, stopping webhook server`);
      cleanup();
      resolve();
    };

    if (abortSignal?.aborted) {
      cleanup();
      resolve();
      return;
    }

    abortSignal?.addEventListener("abort", handleAbort, { once: true });

    server.listen(port, host, () => {
      log(`worktool[${accountId}]: webhook server listening on ${host}:${port}${webhookPath}`);
    });

    server.on("error", (err) => {
      abortSignal?.removeEventListener("abort", handleAbort);
      cleanup();
      reject(err);
    });
  });
}

export async function monitorWorktoolProvider(opts = {}) {
  const cfg = opts.config;
  if (!cfg) {
    throw new Error("Config is required for WorkTool monitor");
  }

  const accountId = opts.accountId || "default";
  await monitorSingleAccount({
    cfg,
    accountId,
    runtime: opts.runtime,
    abortSignal: opts.abortSignal,
  });
}

export function stopWorktoolMonitor(accountId) {
  const server = servers.get(accountId);
  if (!server) return;
  server.close();
  servers.delete(accountId);
}
