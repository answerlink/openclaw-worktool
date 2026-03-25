# Deployment Guide

本文档描述 `openclaw-plugin-worktool` 在 webhook 模式下的部署与联调。

## 1. 插件安装

推荐一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

脚本会优先读取 `.env`，缺失项自动交互询问并回写 `.env`。

CLI 一键安装（需要本机有 `openclaw` 命令）：

```bash
ROBOT_ID=wc11a curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

本地源码一键安装（clone 后，Docker 推荐）：

```bash
git clone https://github.com/answerlink/openclaw-plugin-worktool.git
cd openclaw-plugin-worktool
ROBOT_ID=wc11a bash scripts/install-local.sh
```

上面命令默认走 docker 模式（等价 `scripts/install-local-docker.sh`）。

本地源码一键安装（非 Docker，可选）：

```bash
ROBOT_ID=wc11a bash scripts/install-local-native.sh
```

如需安装指定版本：

```bash
ROBOT_ID=wc11a VERSION=0.2.1 curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

开发联调可用本地目录安装：

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

如果你是 Docker 部署，还需要先配置模型 `.env`（与 `docker-compose.worktool.yml` 同级）：

```dotenv
MODEL_ID=claw-primary
MODEL_BASE_URL=http://127.0.0.1:13030/v1
MODEL_API_KEY=dummy_key
MODEL_API_PROTOCOL=openai-completions
```

## 3. 反向代理（你当前现状）

示例：

- `https://your-public-domain.example.com/wechat/webhook`
- `-> 127.0.0.1:18799/wechat/webhook`

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

5. 可视化页（可选）：

- 在浏览器访问：
  - `https://your-public-domain.example.com/wechat/admin?robotId=<robotId>`
- 用于在线改 `robotId / bridgeBaseUrl / webhook` 参数并发送测试回调。

## 5. 常见问题

- `401 unauthorized`
  - 配置了 `webhookToken` 但请求缺少 `x-worktool-token`。

- `415 content-type must be application/json`
  - 请求头不是 `application/json`。

- `unsupported inbound payload`
  - 回调体中无法提取 `text/senderId/chatId`。

- `worktool channel not configured`
  - 缺少 `robotId` 或 `bridgeBaseUrl`。
