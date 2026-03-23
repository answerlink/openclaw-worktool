import { createReplyPrefixContext } from "openclaw/plugin-sdk";
import { getWorktoolRuntime } from "./runtime.js";
import { postBridge, resolveWorktoolAccount } from "./channel.js";

const DEDUP_TTL_MS = 10 * 60 * 1000;
const inboundDedup = new Map();

function pruneDedup(now) {
  for (const [k, v] of inboundDedup.entries()) {
    if (now - v > DEDUP_TTL_MS) {
      inboundDedup.delete(k);
    }
  }
}

function normalizeTextContent(value) {
  if (typeof value === "string") {
    const s = value.trim();
    if (!s) return "";
    try {
      const parsed = JSON.parse(s);
      if (parsed && typeof parsed === "object") {
        const text = parsed.text ?? parsed.content ?? parsed.body;
        if (typeof text === "string") return text.trim();
      }
    } catch {
      // keep raw string
    }
    return s;
  }
  if (value && typeof value === "object") {
    for (const key of ["text", "content", "body", "message"]) {
      const v = value[key];
      if (typeof v === "string" && v.trim()) {
        return v.trim();
      }
    }
  }
  return "";
}

function pickString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
  }
  return "";
}

function parseTimestamp(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return Date.now();
}

function parseBool(value) {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") {
    const v = value.trim().toLowerCase();
    return v === "1" || v === "true" || v === "yes" || v === "y";
  }
  return false;
}

function buildSyntheticMessageId(parts) {
  return parts
    .map((p) => String(p || "").trim())
    .filter(Boolean)
    .join("|")
    .slice(0, 220);
}

export function normalizeInboundWebhook(payload) {
  if (!payload || typeof payload !== "object") return null;
  const body = payload;

  const spoken = pickString(body.spoken);
  const rawSpoken = pickString(body.rawSpoken);
  const receivedName = pickString(body.receivedName);
  const groupName = pickString(body.groupName);
  const groupRemark = pickString(body.groupRemark);
  const roomType = pickString(body.roomType);
  const textType = Number(pickString(body.textType) || "0");
  const fileBase64 = pickString(body.fileBase64);
  if (spoken || rawSpoken || receivedName || groupName || groupRemark || roomType) {
    const isGroup = (() => {
      if (roomType === "1" || roomType === "3") return true;
      if (roomType === "2" || roomType === "4") return false;
      return Boolean(groupName) || Boolean(groupRemark);
    })();
    const chatType = isGroup ? "group" : "direct";
    const senderName = receivedName || "unknown-user";
    const senderId = `sender:${senderName}`;
    const groupTarget = pickString(groupRemark, groupName);
    const directTarget = pickString(receivedName, groupRemark, groupName, "unknown-user");
    const replyTarget = isGroup ? (groupTarget || directTarget) : directTarget;
    const chatId = isGroup ? (groupTarget || `group:${senderName}`) : `dm:${directTarget}`;
    let text = normalizeTextContent(spoken || rawSpoken);
    if (!text && textType === 2 && fileBase64) {
      text = `[图片消息] base64_length=${fileBase64.length}`;
    }
    if (!text && textType > 0) {
      text = `[非文本消息] textType=${textType}`;
    }
    if (rawSpoken && rawSpoken !== text) {
      text = `${text}\n\n[rawSpoken]\n${rawSpoken}`;
    }
    if (text) {
      const timestamp = parseTimestamp(body.timestamp ?? body.create_time);
      return {
        messageId: pickString(
          body.messageId,
          body.msgid,
          buildSyntheticMessageId([chatId, senderName, timestamp, rawSpoken || spoken]),
        ),
        text,
        senderId,
        senderName,
        chatId,
        chatType,
        mentionedBot: parseBool(body.atMe),
        timestamp,
        replyTarget,
      };
    }
  }

  const event = body.event && typeof body.event === "object" ? body.event : null;
  const message = event?.message && typeof event.message === "object" ? event.message : null;
  const sender = event?.sender && typeof event.sender === "object" ? event.sender : null;
  const chat = event?.chat && typeof event.chat === "object" ? event.chat : null;

  if (event && message && sender) {
    const senderIdObj = sender.sender_id && typeof sender.sender_id === "object" ? sender.sender_id : null;
    const text = normalizeTextContent(message.content);
    const senderId = pickString(senderIdObj?.open_id, senderIdObj?.user_id, sender.open_id, sender.user_id, sender.id);
    const chatId = pickString(message.chat_id, chat?.chat_id, chat?.id, senderId);
    const chatType = pickString(message.chat_type, chat?.chat_type).toLowerCase() === "group" ? "group" : "direct";

    if (text && senderId) {
      return {
        messageId: pickString(message.message_id, body.event_id, `${chatId}-${Date.now()}`),
        text,
        senderId,
        senderName: pickString(sender.name, sender.display_name, senderId),
        chatId,
        chatType,
        mentionedBot: Boolean(event.mentioned_bot ?? event.was_mentioned),
        timestamp: parseTimestamp(message.create_time ?? body.timestamp),
        replyTarget: pickString(chatId, senderId),
      };
    }
  }

  const text2 = normalizeTextContent(body.content ?? body.text ?? body.message ?? body.msg);
  const senderId2 = pickString(body.senderId, body.from, body.from_wxid, body.sender, body.userid, body.user_id);
  const chatId2 = pickString(body.chatId, body.room_wxid, body.conversation_id, body.receiver, senderId2);

  if (text2 && senderId2) {
    const rawType = pickString(body.chatType, body.conversation_type, body.scene, body.type).toLowerCase();
    const isGroup = rawType.includes("group") || rawType.includes("room");
    return {
      messageId: pickString(body.messageId, body.msgid, body.msg_id, `${chatId2}-${Date.now()}`),
      text: text2,
      senderId: senderId2,
      senderName: pickString(body.senderName, body.from_name, body.nickname, senderId2),
      chatId: chatId2,
      chatType: isGroup ? "group" : "direct",
      mentionedBot: Boolean(body.is_at || body.mentionedBot),
      timestamp: parseTimestamp(body.timestamp ?? body.create_time),
      replyTarget: pickString(body.replyTarget, chatId2, senderId2),
    };
  }

  return null;
}

export async function handleInboundWebhook(params) {
  const { cfg, payload, accountId, runtime } = params;
  const msg = normalizeInboundWebhook(payload);
  if (!msg) {
    throw new Error("unsupported inbound payload: cannot extract text/sender/chat fields");
  }

  const now = Date.now();
  pruneDedup(now);
  const dedupKey = `${accountId || "default"}:${msg.messageId}`;
  if (inboundDedup.has(dedupKey)) {
    return { ok: true, duplicate: true, messageId: msg.messageId };
  }
  inboundDedup.set(dedupKey, now);

  const account = resolveWorktoolAccount(cfg, accountId);
  if (!account.robotId || !account.bridgeBaseUrl) {
    throw new Error("worktool channel not configured: require robotId + bridgeBaseUrl");
  }
  const wasMentioned = account.forceMentioned ? true : (msg.mentionedBot ?? false);

  const core = getWorktoolRuntime();
  const route = core.channel.routing.resolveAgentRoute({
    cfg,
    channel: "worktool",
    accountId: account.accountId,
    peer: {
      kind: msg.chatType === "group" ? "group" : "direct",
      id: msg.chatType === "group" ? msg.chatId : msg.senderId,
    },
  });

  const envelopeOptions = core.channel.reply.resolveEnvelopeFormatOptions(cfg);
  const bodyForAgent = `${msg.senderName || msg.senderId}: ${msg.text}`;
  const body = core.channel.reply.formatAgentEnvelope({
    channel: "WeChat",
    from: msg.chatType === "group" ? `${msg.chatId}:${msg.senderId}` : msg.senderId,
    timestamp: new Date(msg.timestamp),
    envelope: envelopeOptions,
    body: bodyForAgent,
  });

  const from = `wechat:${msg.senderId}`;
  const to = msg.chatType === "group" ? `chat:${msg.chatId}` : `user:${msg.senderId}`;

  const ctxPayload = core.channel.reply.finalizeInboundContext({
    Body: body,
    BodyForAgent: bodyForAgent,
    RawBody: msg.text,
    CommandBody: msg.text,
    From: from,
    To: to,
    SessionKey: route.sessionKey,
    AccountId: route.accountId,
    ChatType: msg.chatType,
    GroupSubject: msg.chatType === "group" ? msg.chatId : undefined,
    SenderName: msg.senderName || msg.senderId,
    SenderId: msg.senderId,
    Provider: "worktool",
    Surface: "worktool",
    MessageSid: msg.messageId,
    Timestamp: msg.timestamp,
    WasMentioned: wasMentioned,
    OriginatingChannel: "worktool",
    OriginatingTo: msg.replyTarget,
  });
  runtime?.log?.(
    `worktool[${account.accountId}]: dispatch start message=${msg.messageId} chatType=${msg.chatType} replyTarget=${msg.replyTarget} wasMentioned=${String(wasMentioned)} forceMentioned=${String(account.forceMentioned)}`,
  );

  const prefixContext = createReplyPrefixContext({ cfg, agentId: route.agentId });
  const { dispatcher, replyOptions, markDispatchIdle } = core.channel.reply.createReplyDispatcherWithTyping({
    responsePrefix: prefixContext.responsePrefix,
    responsePrefixContextProvider: prefixContext.responsePrefixContextProvider,
    humanDelay: core.channel.reply.resolveHumanDelayConfig(cfg, route.agentId),
    deliver: async (payloadChunk) => {
      const text = String(payloadChunk?.text || "").trim();
      runtime?.log?.(
        `worktool[${account.accountId}]: deliver chunk message=${msg.messageId} textLen=${text.length}`,
      );
      if (!text) {
        runtime?.log?.(`worktool[${account.accountId}]: deliver chunk skipped (empty text)`);
        return;
      }
      await postBridge(account.bridgeBaseUrl, account.robotId, [
        {
          type: 203,
          titleList: [msg.replyTarget],
          receivedContent: text,
        },
      ]);
      runtime?.log?.(
        `worktool[${account.accountId}]: deliver sent message=${msg.messageId} target=${msg.replyTarget}`,
      );
    },
    onError: async (err) => {
      runtime?.error?.(`worktool[${account.accountId}]: reply dispatch error: ${String(err)}`);
    },
  });

  await core.channel.reply.dispatchReplyFromConfig({
    ctx: ctxPayload,
    cfg,
    dispatcher,
    replyOptions,
  });
  runtime?.log?.(`worktool[${account.accountId}]: dispatch returned message=${msg.messageId}`);

  await dispatcher.waitForIdle?.();
  markDispatchIdle?.();
  runtime?.log?.(`worktool[${account.accountId}]: dispatcher idle message=${msg.messageId}`);

  runtime?.log?.(`worktool[${account.accountId}]: inbound dispatched message=${msg.messageId} session=${route.sessionKey}`);

  return {
    ok: true,
    duplicate: false,
    messageId: msg.messageId,
    sessionKey: route.sessionKey,
    accountId: route.accountId,
  };
}
