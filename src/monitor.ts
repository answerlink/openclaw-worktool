import * as http from "node:http";
import type { ClawdbotConfig, RuntimeEnv } from "openclaw/plugin-sdk";
import { resolveWorktoolAccount } from "./channel.js";
import { handleInboundWebhook, normalizeInboundWebhook } from "./inbound.js";
import { getWorktoolRuntime } from "./runtime.js";

export type MonitorWorktoolOpts = {
  config?: ClawdbotConfig;
  runtime?: RuntimeEnv;
  abortSignal?: AbortSignal;
  accountId?: string;
};

const servers = new Map<string, http.Server>();
const MAX_BODY_BYTES = 1024 * 1024;
const BODY_TIMEOUT_MS = 30_000;

function isJsonContentType(value: string | string[] | undefined): boolean {
  const first = Array.isArray(value) ? value[0] : value;
  if (!first) return false;
  const mediaType = first.split(";", 1)[0]?.trim().toLowerCase();
  return mediaType === "application/json" || Boolean(mediaType?.endsWith("+json"));
}

function readJsonBody(req: http.IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;

    const timer = setTimeout(() => {
      reject(new Error("request body timeout"));
    }, BODY_TIMEOUT_MS);

    req.on("data", (chunk: Buffer) => {
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

function sendJson(res: http.ServerResponse, status: number, data: Record<string, unknown>) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(data));
}

function normalizePath(req: http.IncomingMessage): string {
  const url = req.url || "/";
  return new URL(url, "http://localhost").pathname;
}

function readQueryRobotId(req: http.IncomingMessage): string {
  const url = req.url || "/";
  return new URL(url, "http://localhost").searchParams.get("robotId")?.trim() || "";
}

function readHeaderToken(req: http.IncomingMessage): string {
  return String(req.headers["x-worktool-token"] || "").trim();
}

function isTokenAuthorized(req: http.IncomingMessage, account: { webhookToken?: string; robotId?: string }): boolean {
  const headerToken = readHeaderToken(req);
  const queryRobotId = readQueryRobotId(req);
  const providedToken = headerToken || queryRobotId;
  // Priority 1: explicit webhook token
  if (account.webhookToken) {
    return providedToken.length > 0 && providedToken === account.webhookToken;
  }
  // Priority 2: use robotId as webhook credential (fits WorkTool unique client key)
  if (account.robotId) {
    return providedToken.length > 0 && providedToken === account.robotId;
  }
  return true;
}

async function monitorSingleAccount(params: {
  cfg: ClawdbotConfig;
  accountId: string;
  runtime?: RuntimeEnv;
  abortSignal?: AbortSignal;
}) {
  const { cfg, accountId, runtime, abortSignal } = params;
  const account = resolveWorktoolAccount(cfg, accountId);
  const host = account.webhookHost || "0.0.0.0";
  const port = Number(account.webhookPort || 18799);
  const path = account.webhookPath || "/wechat/webhook";

  const log = runtime?.log ?? console.log;
  const error = runtime?.error ?? console.error;

  const server = http.createServer(async (req, res) => {
    const reqPath = normalizePath(req);

    if (reqPath !== path) {
      sendJson(res, 404, { ok: false, error: "not found" });
      return;
    }

    if (req.method === "GET") {
      sendJson(res, 200, {
        ok: true,
        channel: "worktool",
        path,
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
      const account = resolveWorktoolAccount(cfg, accountId);
      let sessionKey: string | null = null;
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

      // Process asynchronously to keep webhook response fast.
      void handleInboundWebhook({
        cfg,
        payload,
        accountId,
        runtime,
      }).catch((err) => {
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

  await new Promise<void>((resolve, reject) => {
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
      log(`worktool[${accountId}]: webhook server listening on ${host}:${port}${path}`);
    });

    server.on("error", (err) => {
      abortSignal?.removeEventListener("abort", handleAbort);
      cleanup();
      reject(err);
    });
  });
}

export async function monitorWorktoolProvider(opts: MonitorWorktoolOpts = {}): Promise<void> {
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

export function stopWorktoolMonitor(accountId: string) {
  const server = servers.get(accountId);
  if (!server) return;
  server.close();
  servers.delete(accountId);
}
