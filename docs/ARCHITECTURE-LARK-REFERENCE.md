# WorkTool 插件架构说明（参考 openclaw-lark）

本文档记录 `openclaw-plugin-worktool` 的目录边界，并对齐 `~/projects/openclaw-lark` 的分层思路，供后续持续演进。

## 1. 参考飞书插件的分层边界

飞书插件中两层边界非常清晰：

- `skills/`：给 Agent 的能力说明与使用约束（提示词资产）。
- `src/tools/`：真正可执行的工具实现（API 调用、参数校验、返回结构）。

在 WorkTool 插件中同样建议沿用：

- `skills/` 只放“做什么、怎么调用、边界是什么”。
- `src/tools/` 只放“如何做”的代码实现，不夹杂渠道消息路由逻辑。
- `src/channel*` 与 `src/inbound*` 负责“消息编排与会话路由”，不做业务工具实现。

## 2. 当前 worktool 插件目录职责

- `index.ts/js`
  - 插件入口，注册 channel，并注入 runtime。

- `src/channel.ts/js`
  - ChannelPlugin 定义。
  - 账号解析、配置 schema。
  - outbound 发消息（调用 WorkTool bridge）。
  - gateway 启停（启动 webhook monitor）。

- `src/monitor.ts/js`
  - 启动 HTTP webhook server。
  - 请求鉴权、content-type、body 限流与解析。
  - 把有效 payload 转给 inbound handler。

- `src/inbound.ts/js`
  - 入站回调标准化（feishu-like / worktool raw / simple curl）。
  - 路由到 OpenClaw agent 会话。
  - 调用 reply dispatcher，把模型回复回推到微信。

- `src/runtime.ts/js`
  - 持有并暴露插件 runtime 单例。

## 3. 推荐 webhook 规范（尽量对齐飞书回调信息量）

推荐上游回调尽量采用下述结构：

```json
{
  "header": {
    "event_id": "evt-20260320-0001",
    "event_type": "im.message.receive_v1",
    "timestamp": "1760000000000"
  },
  "event": {
    "message": {
      "message_id": "wxmsg-001",
      "chat_id": "room_or_user_id",
      "chat_type": "group",
      "content": "{\"text\":\"你好，小龙虾\"}",
      "create_time": "1760000000000"
    },
    "sender": {
      "sender_id": {
        "open_id": "wxid_xxx",
        "user_id": "wxid_xxx"
      },
      "name": "张三"
    },
    "chat": {
      "chat_id": "room_or_user_id",
      "chat_type": "group"
    },
    "mentioned_bot": false
  }
}
```

字段价值对照：

- `message_id`：去重、排障追踪。
- `chat_id + chat_type`：会话路由（群/私聊）。
- `sender.sender_id.* + name`：身份和展示名。
- `content`：消息正文（建议 JSON 内含 `text`，兼容后续多模态字段）。
- `timestamp/create_time`：时序与日志关联。
- `mentioned_bot`：群场景可用于 mention gate。

## 4. 兼容输入（便于联调）

插件当前兼容三类入站格式：

1. 上面推荐的 feishu-like envelope。
2. 常见 worktool 原始字段（如 `msgid/from/room_wxid/content`）。
3. 最简 curl 字段：`text + senderId + chatId + chatType`。

你当前 WorkTool 业务字段也已原生支持：

- `spoken`
- `rawSpoken`
- `receivedName`
- `groupName`
- `groupRemark`
- `roomType`（1/2/3/4）
- `atMe`
- `textType`
- `fileBase64`
