import { DEFAULT_ACCOUNT_ID, type ChannelPlugin } from "openclaw/plugin-sdk";

type WorktoolAccount = {
  accountId: string;
  name?: string;
  enabled?: boolean;
  robotId?: string;
  bridgeBaseUrl?: string;
};

function inferFileTypeFromUrl(urlValue: string): "image" | "audio" | "video" | "*" {
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

async function postBridge(baseUrl: string, robotId: string, payload: Record<string, unknown>) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const base = baseUrl.replace(/\/+$/, "");
    const url = `${base}/api/v1/openclaw/push/${encodeURIComponent(robotId)}`;
    const resp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    if (!resp.ok) {
      const body = await resp.text();
      throw new Error(`worktool bridge error ${resp.status}: ${body.slice(0, 300)}`);
    }
    return await resp.json().catch(() => ({}));
  } finally {
    clearTimeout(timer);
  }
}

function getWorktoolConfig(cfg: any) {
  return cfg?.channels?.worktool ?? {};
}

function listAccountIds(cfg: any): string[] {
  const c = getWorktoolConfig(cfg);
  const ids = Object.keys(c?.accounts ?? {});
  return ids.length > 0 ? ids : [DEFAULT_ACCOUNT_ID];
}

function resolveAccount(cfg: any, accountId?: string): WorktoolAccount {
  const c = getWorktoolConfig(cfg);
  const id = accountId || DEFAULT_ACCOUNT_ID;
  const acc = (id === DEFAULT_ACCOUNT_ID ? c : c?.accounts?.[id]) ?? {};
  return {
    accountId: id,
    name: acc.name || id,
    enabled: acc.enabled !== false,
    robotId: acc.robotId || c.robotId,
    bridgeBaseUrl: acc.bridgeBaseUrl || c.bridgeBaseUrl,
  };
}

export const worktoolPlugin: ChannelPlugin<WorktoolAccount> = {
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
  config: {
    listAccountIds,
    resolveAccount,
    defaultAccountId: () => DEFAULT_ACCOUNT_ID,
    isConfigured: (account) => Boolean(account.robotId && account.bridgeBaseUrl),
    describeAccount: (account) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled !== false,
      configured: Boolean(account.robotId && account.bridgeBaseUrl),
      robotId: account.robotId,
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
      const account = resolveAccount(cfg, accountId);
      if (!account.robotId || !account.bridgeBaseUrl) {
        throw new Error("worktool channel not configured: require robotId + bridgeBaseUrl");
      }
      const data = await postBridge(account.bridgeBaseUrl, account.robotId, {
          list: [
            {
              type: 203,
              receiver: String(to || "").trim(),
              content: String(text || ""),
            },
          ],
      });
      return {
        channel: "worktool" as const,
        to: String(to || "").trim(),
        messageId: String(data?.message_id || data?.data || `wt-${Date.now()}`),
      };
    },
    sendMedia: async ({ cfg, to, text, mediaUrl, accountId }) => {
      const account = resolveAccount(cfg, accountId);
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
      const data = await postBridge(account.bridgeBaseUrl, account.robotId, {
          list: [
            {
              type: 218,
              receiver: String(to || "").trim(),
              object_name: objectName,
              file_url: urlValue,
              file_type: fileType,
              extra_text: String(text || ""),
            },
          ],
      });
      return {
        channel: "worktool" as const,
        to: String(to || "").trim(),
        messageId: String(data?.message_id || data?.data || `wt-${Date.now()}`),
      };
    },
  },
};
