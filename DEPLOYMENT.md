# Deployment Guide

本文档描述如何将 `openclaw-plugin-worktool` 以本地插件方式接入 OpenClaw。

## 1. Clone Repository

```bash
git clone <your-repo-url>
cd openclaw-plugin-worktool
```

## 2. Install Dependencies

```bash
npm install
```

> 当前仓库主要提供运行时代码；如果后续增加构建流程，请在此基础上补充 `npm run build`。

## 3. Place Plugin Into OpenClaw Extensions

按 `package.json` 里的约定，默认本地安装路径是：

```text
extensions/worktool
```

将本仓库放到 OpenClaw 工作目录对应的 `extensions/worktool` 下，或建立软链接（推荐开发阶段）：

```bash
ln -s /absolute/path/openclaw-plugin-worktool /absolute/path/to/openclaw/extensions/worktool
```

## 4. Configure OpenClaw

在 OpenClaw 配置中添加：

```json
{
  "channels": {
    "worktool": {
      "robotId": "robot-001",
      "bridgeBaseUrl": "http://127.0.0.1:9000"
    }
  }
}
```

多账号配置示例：

```json
{
  "channels": {
    "worktool": {
      "robotId": "robot-default",
      "bridgeBaseUrl": "http://127.0.0.1:9000",
      "accounts": {
        "ops": {
          "name": "Ops Bot",
          "enabled": true,
          "robotId": "robot-ops",
          "bridgeBaseUrl": "http://127.0.0.1:9000"
        }
      }
    }
  }
}
```

## 5. Start And Verify

1. 启动 WorkTool bridge 服务，并确保能从 OpenClaw 进程访问。
2. 启动 OpenClaw。
3. 在 OpenClaw 中选择 `WorkTool Bridge` 渠道发送一条消息。
4. 若失败，优先检查：
   - `robotId` 是否正确
   - `bridgeBaseUrl` 是否可访问
   - `receiver` 是否为可识别的群名或用户备注

## Troubleshooting

- `worktool channel not configured: require robotId + bridgeBaseUrl`
  - 配置缺少 `robotId` 或 `bridgeBaseUrl`。
- `worktool bridge error 4xx/5xx`
  - bridge 服务返回错误，检查 bridge 日志和请求体字段。
- 请求超时
  - 当前超时为 15 秒，检查网络连通性或 bridge 负载。
