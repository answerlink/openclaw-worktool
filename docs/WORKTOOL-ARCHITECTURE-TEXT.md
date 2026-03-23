# WorkTool 插件架构图（纯文本）

```text
Wechat / WorkTool 平台
  |
  |  POST https://your-public-domain.example.com/wechat/webhook
  |   或 https://your-public-domain.example.com/wechat/webhook?robotId=<robotId>  (重要兼容入口)
  |  Headers:
  |    Content-Type: application/json
  |    x-worktool-token: <robotId 或 webhookToken>   (可选，query 已带 robotId 时可不传)
  |  Body:
  |    spoken/rawSpoken/receivedName/groupName/groupRemark/roomType/atMe/textType/fileBase64
  v
Nginx
  |
  |  反代到
  v
宿主机 OpenClaw 进程
  |
  +-- openclaw-plugin-worktool
      |
      +-- index.ts/js
      |    - 注册 channel(worktool)
      |    - 注入 runtime(setWorktoolRuntime)
      |
      +-- src/channel.ts/js
      |    - ChannelPlugin 定义（meta/capabilities/configSchema）
      |    - outbound.sendText/sendMedia（调用 WorkTool bridge）
      |    - gateway.startAccount -> 启动 monitor
      |
      +-- src/monitor.ts/js
      |    - 启动 HTTP server (默认 0.0.0.0:18799/wechat/webhook)
      |    - 鉴权：
      |        1) webhookToken（若配置）
      |        2) 否则 robotId（优先取 x-worktool-token；无 header 时取 query.robotId）
      |    - 校验 Content-Type / body 大小 / 超时
      |    - 交给 inbound.handleInboundWebhook
      |
      +-- src/inbound.ts/js
      |    - 回调标准化 normalizeInboundWebhook：
      |        A) WorkTool 字段（spoken...）
      |        B) feishu-like envelope
      |        C) 兜底 raw/simple
      |    - 生成会话键（无 senderId 时用 receivedName/group 信息）
      |    - 调 OpenClaw runtime:
      |        routing.resolveAgentRoute
      |        reply.dispatchReplyFromConfig
      |    - deliver 回调里再次调用 postBridge 发回微信
      |
      +-- src/runtime.ts/js
           - 保存 runtime 单例，供 inbound/dispatch 使用

OpenClaw Runtime 内部链路（插件调用）
  |
  | inbound ctx (Body/From/To/SessionKey/MessageSid...)
  v
Agent 路由与会话
  |
  v
LLM 生成回复（可分片）
  |
  v
worktool deliver() 回调
  |
  | POST bridgeBaseUrl/wework/sendRawMessage?robotId={robotId}
  | payload:
  |   socketType=2
  |   list[]:
  |     - 文本: type=203, titleList, receivedContent
  |     - 文件: type=218, titleList, objectName, fileUrl, fileType, extraText
  v
WorkTool RPA 发送到微信
```

## 关键数据映射（你当前协议 -> 插件内部）

- `spoken/rawSpoken` -> `msg.text`
- `receivedName` -> `senderName`，`senderId`（合成）
- `groupRemark/groupName` -> `chatId/replyTarget`（群）
- `roomType` -> `chatType`
  - `1/3 = group`
  - `2/4 = direct`
- `atMe` -> `mentionedBot`
- `textType/fileBase64` -> 非文本时转成可读占位文本，仍可驱动 Agent

## 目录分工（参考 openclaw-lark 思路）

- `skills/`（后续建议新增）
  - 只放能力说明、调用约束、提示词资产
- `src/tools/`（后续建议新增）
  - 只放业务工具实现（API 封装）
  - 不放渠道消息编排
- `src/channel + src/monitor + src/inbound`
  - 只做“消息接入、鉴权、标准化、路由、回复下发”
  - 不承载具体业务工具逻辑
