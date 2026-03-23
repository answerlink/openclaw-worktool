import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk";

const DEFAULT_WEBHOOK_HOST = "0.0.0.0";
const DEFAULT_WEBHOOK_PORT = 18799;
const DEFAULT_WEBHOOK_PATH = "/wechat/webhook";
const DEFAULT_WORKTOOL_BASE_URL = "https://api.worktool.ymdyes.cn";

function inferFileTypeFromUrl(urlValue) {
  try {
    const path = new URL(urlValue).pathname.toLowerCase();
    if (/\.(png|jpe?g|gif|webp|bmp|svg)$/.test(path)) return "image";
    if (/\.(mp3|wav|m4a|aac|ogg|flac)$/.test(path)) return "audio";
    if (/\.(mp4|mov|mkv|avi|webm)$/.test(path)) return "video";
  } catch {
    // ignore parse failures and fallback
  }
  return "*";
}

export async function postBridge(baseUrl, robotId, list) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const base = String(baseUrl || "").replace(/\/+$/, "");
    const url = `${base}/wework/sendRawMessage?robotId=${encodeURIComponent(robotId)}`;
    try {
      const first = list?.[0] ?? {};
      const targets = Array.isArray(first.titleList) ? first.titleList : [];
      console.log(
        `[worktool-bridge] request url=${url} type=${String(first.type ?? "")} targets=${JSON.stringify(targets).slice(0, 300)}`,
      );
    } catch {
      // ignore logging errors
    }
    const resp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        socketType: 2,
        list,
      }),
      signal: controller.signal,
    });
    console.log(`[worktool-bridge] response status=${resp.status} ok=${resp.ok}`);
    if (!resp.ok) {
      const body = await resp.text();
      console.error(`[worktool-bridge] error-body=${body.slice(0, 500)}`);
      throw new Error(`worktool bridge error ${resp.status}: ${body.slice(0, 300)}`);
    }
    return await resp.json().catch(() => ({}));
  } finally {
    clearTimeout(timer);
  }
}

export function getWorktoolConfig(cfg) {
  return cfg?.channels?.worktool ?? {};
}

function listAccountIds(cfg) {
  const c = getWorktoolConfig(cfg);
  const ids = Object.keys(c?.accounts ?? {});
  return ids.length > 0 ? ids : [DEFAULT_ACCOUNT_ID];
}

export function resolveWorktoolAccount(cfg, accountId) {
  const c = getWorktoolConfig(cfg);
  const id = accountId || DEFAULT_ACCOUNT_ID;
  const acc = (id === DEFAULT_ACCOUNT_ID ? c : c?.accounts?.[id]) ?? {};
  return {
    accountId: id,
    name: acc.name || id,
    enabled: acc.enabled !== false,
    robotId: acc.robotId || c.robotId,
    bridgeBaseUrl: acc.bridgeBaseUrl || c.bridgeBaseUrl || DEFAULT_WORKTOOL_BASE_URL,
    webhookHost: acc.webhookHost || c.webhookHost || DEFAULT_WEBHOOK_HOST,
    webhookPort: Number(acc.webhookPort || c.webhookPort || DEFAULT_WEBHOOK_PORT),
    webhookPath: acc.webhookPath || c.webhookPath || DEFAULT_WEBHOOK_PATH,
    webhookToken: acc.webhookToken || c.webhookToken,
    forceMentioned: (acc.forceMentioned ?? c.forceMentioned ?? false) === true,
  };
}

async function sendBridgeText(account, to, text) {
  if (!account.robotId || !account.bridgeBaseUrl) {
    throw new Error("worktool channel not configured: require robotId + bridgeBaseUrl");
  }
  const data = await postBridge(account.bridgeBaseUrl, account.robotId, [
    {
      type: 203,
      titleList: [String(to || "").trim()],
      receivedContent: String(text || ""),
    },
  ]);
  return {
    channel: "worktool",
    to: String(to || "").trim(),
    messageId: String(data?.message_id || data?.data || `wt-${Date.now()}`),
  };
}

async function sendBridgeMedia(account, to, text, mediaUrl) {
  if (!account.robotId || !account.bridgeBaseUrl) {
    throw new Error("worktool channel not configured: require robotId + bridgeBaseUrl");
  }
  const urlValue = String(mediaUrl || "").trim();
  if (!urlValue) {
    throw new Error("worktool sendMedia requires mediaUrl");
  }

  const objectName = (() => {
    try {
      const u = new URL(urlValue);
      const n = u.pathname.split("/").pop() || "";
      return n || `file-${Date.now()}`;
    } catch {
      return `file-${Date.now()}`;
    }
  })();

  const fileType = inferFileTypeFromUrl(urlValue);

  const data = await postBridge(account.bridgeBaseUrl, account.robotId, [
    {
      type: 218,
      titleList: [String(to || "").trim()],
      objectName: objectName,
      fileUrl: urlValue,
      fileType,
      extraText: String(text || ""),
    },
  ]);
  return {
    channel: "worktool",
    to: String(to || "").trim(),
    messageId: String(data?.message_id || data?.data || `wt-${Date.now()}`),
  };
}

export const worktoolPlugin = {
  id: "worktool",
  meta: {
    id: "worktool",
    label: "WorkTool",
    selectionLabel: "WorkTool Bridge",
    docsPath: "/channels/worktool",
    docsLabel: "worktool",
    blurb: "Send replies via WorkTool bridge API",
    order: 96,
  },
  capabilities: {
    chatTypes: ["direct", "group"],
    media: true,
    nativeCommands: false,
  },
  reload: { configPrefixes: ["channels.worktool"] },
  configSchema: {
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        enabled: { type: "boolean" },
        robotId: { type: "string" },
        bridgeBaseUrl: { type: "string" },
        webhookHost: { type: "string" },
        webhookPort: { type: "integer", minimum: 1 },
        webhookPath: { type: "string" },
        webhookToken: { type: "string" },
        forceMentioned: { type: "boolean" },
        accounts: {
          type: "object",
          additionalProperties: {
            type: "object",
            properties: {
              enabled: { type: "boolean" },
              name: { type: "string" },
              robotId: { type: "string" },
              bridgeBaseUrl: { type: "string" },
              webhookHost: { type: "string" },
              webhookPort: { type: "integer", minimum: 1 },
              webhookPath: { type: "string" },
              webhookToken: { type: "string" },
              forceMentioned: { type: "boolean" },
            },
          },
        },
      },
    },
  },
  config: {
    listAccountIds,
    resolveAccount: resolveWorktoolAccount,
    defaultAccountId: () => DEFAULT_ACCOUNT_ID,
    isConfigured: (account) => Boolean(account.robotId && account.bridgeBaseUrl),
    describeAccount: (account) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled !== false,
      configured: Boolean(account.robotId && account.bridgeBaseUrl),
      robotId: account.robotId,
      webhookHost: account.webhookHost,
      webhookPort: account.webhookPort,
      webhookPath: account.webhookPath,
      forceMentioned: account.forceMentioned,
    }),
  },
  messaging: {
    normalizeTarget: (target) => target.trim(),
    targetResolver: {
      looksLikeId: (id) => Boolean(id?.trim()),
      hint: "<群名|用户备注>",
    },
  },
  outbound: {
    deliveryMode: "direct",
    sendText: async ({ cfg, to, text, accountId }) => {
      const account = resolveWorktoolAccount(cfg, accountId);
      return sendBridgeText(account, String(to || "").trim(), String(text || ""));
    },
    sendMedia: async ({ cfg, to, text, mediaUrl, accountId }) => {
      const account = resolveWorktoolAccount(cfg, accountId);
      return sendBridgeMedia(
        account,
        String(to || "").trim(),
        String(text || ""),
        String(mediaUrl || "").trim(),
      );
    },
  },
  status: {
    defaultRuntime: {
      accountId: DEFAULT_ACCOUNT_ID,
      running: false,
      lastStartAt: null,
      lastStopAt: null,
      lastError: null,
      port: null,
    },
    buildChannelSummary: ({ snapshot }) => ({
      configured: snapshot.configured ?? false,
      running: snapshot.running ?? false,
      lastStartAt: snapshot.lastStartAt ?? null,
      lastStopAt: snapshot.lastStopAt ?? null,
      lastError: snapshot.lastError ?? null,
      port: snapshot.port ?? null,
    }),
    buildAccountSnapshot: ({ account, runtime }) => ({
      accountId: account.accountId,
      enabled: account.enabled,
      configured: Boolean(account.robotId && account.bridgeBaseUrl),
      name: account.name,
      robotId: account.robotId,
      running: runtime?.running ?? false,
      lastStartAt: runtime?.lastStartAt ?? null,
      lastStopAt: runtime?.lastStopAt ?? null,
      lastError: runtime?.lastError ?? null,
      port: runtime?.port ?? null,
    }),
  },
  gateway: {
    startAccount: async (ctx) => {
      const { monitorWorktoolProvider } = await import("./monitor.js");
      const account = resolveWorktoolAccount(ctx.cfg, ctx.accountId);
      const port = account.webhookPort ?? DEFAULT_WEBHOOK_PORT;
      ctx.setStatus({ accountId: ctx.accountId, port });
      ctx.log?.info(
        `starting worktool[${ctx.accountId}] webhook on ${account.webhookHost}:${port}${account.webhookPath}`,
      );
      return monitorWorktoolProvider({
        config: ctx.cfg,
        runtime: ctx.runtime,
        abortSignal: ctx.abortSignal,
        accountId: ctx.accountId,
      });
    },
    stopAccount: async (ctx) => {
      ctx.log?.info(`stopping worktool[${ctx.accountId}]`);
    },
  },
};
