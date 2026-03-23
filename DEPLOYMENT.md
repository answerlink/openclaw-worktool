# Deployment Guide

本文档描述 `openclaw-plugin-worktool` 在 webhook 模式下的部署与联调。

## 1. 插件安装

```bash
openclaw plugins install /absolute/path/openclaw-plugin-worktool
```

## 2. OpenClaw 配置

至少保证以下字段可用：

- `channels.worktool.robotId`
- `channels.worktool.bridgeBaseUrl`
- `channels.worktool.webhookHost`（建议 `0.0.0.0`）
- `channels.worktool.webhookPort`（你的场景为 `18799`）
- `channels.worktool.webhookPath`（你的场景为 `/wechat/webhook`）

## 3. 反向代理（你当前现状）

示例：

- `https://your-public-domain.example.com/wechat/webhook`
- `-> 10.21.8.6:18799/wechat/webhook`

确保代理透传：

- `Content-Type: application/json`
- `x-worktool-token`（若你启用 token）

## 4. 启动与验证

1. 启动 OpenClaw（并确保 worktool 渠道网关已启动）。
2. 访问健康检查：

```bash
curl -i https://your-public-domain.example.com/wechat/webhook
```

3. 发送最简回调：

```bash
curl -X POST 'https://your-public-domain.example.com/wechat/webhook' \
  -H 'Content-Type: application/json' \
  -H 'x-worktool-token: 893724599f7244febceeb66b03825677' \
  -d '{"spoken":"部署联调消息","rawSpoken":"部署联调消息","receivedName":"仑哥","groupName":"测试群1","groupRemark":"测试群1备注名","roomType":"1","atMe":true,"textType":"1","fileBase64":""}'
```

4. 检查日志关键字：

- `webhook server listening`
- `inbound dispatched message=`
- bridge 成功回包

## 5. 常见问题

- `401 unauthorized`
  - 配置了 `webhookToken` 但请求缺少 `x-worktool-token`。

- `415 content-type must be application/json`
  - 请求头不是 `application/json`。

- `unsupported inbound payload`
  - 回调体中无法提取 `text/senderId/chatId`。

- `worktool channel not configured`
  - 缺少 `robotId` 或 `bridgeBaseUrl`。
