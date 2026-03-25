# openclaw-plugin-worktool

OpenClaw 的 WorkTool 渠道插件，支持：

- 出站：将 OpenClaw 回复发送到微信（经 WorkTool bridge）。
- 入站：接收 WorkTool webhook 回调并路由到小龙虾 Agent。

## 安装

方式 1：一键安装（Docker 用户推荐，无需 openclaw CLI）

```bash
curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

说明：

- 脚本优先读取当前目录 `.env`。
- 缺失关键项会交互询问（`ROBOT_ID / PUBLIC_BASE_URL / MODEL_*`），并自动回写 `.env`。
- 也可提前传环境变量实现无交互安装（适合自动化）。

安装指定版本：

```bash
VERSION=0.2.1 curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

如果你的 `docker-compose.worktool.yml` 或配置目录不在当前目录，可传参：

```bash
ROBOT_ID=wctestid \
COMPOSE_FILE=/path/to/docker-compose.worktool.yml \
OPENCLAW_CONFIG=/path/to/runtime/config/openclaw.json \
PLUGIN_HOST_DIR=/path/to/openclaw-plugin-worktool \
curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

方式 2：一键安装（CLI 模式，需要本机有 `openclaw` 命令）

```bash
ROBOT_ID=wctestid curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

安装指定版本：

```bash
ROBOT_ID=wctestid VERSION=0.2.1 curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

可选覆盖 WorkTool 地址（私有化部署）：

```bash
ROBOT_ID=wctestid BRIDGE_BASE_URL=https://your-private-worktool.example.com \
curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

方式 3：源码一键安装（clone 后本地自测）

```bash
git clone https://github.com/answerlink/openclaw-plugin-worktool.git
cd openclaw-plugin-worktool
ROBOT_ID=wctestid bash scripts/install-local.sh
```

`install-local.sh` 默认是 `Docker` 模式（推荐，本地 docker 运行 OpenClaw 的场景）：

- 等价于：`bash scripts/install-local-docker.sh`
- 常用可覆盖参数：
  - `OPENCLAW_CONFIG`（默认 `../runtime/config/openclaw.json`）
  - `COMPOSE_FILE`（默认 `../docker-compose.worktool.yml`）
  - `SERVICE_NAME`（默认 `openclaw-worktool`）

源码一键安装（非 Docker，可选）：

```bash
ROBOT_ID=wctestid bash scripts/install-local-native.sh
```

一键安装脚本会自动写入 OpenClaw 配置（native 默认 `~/.openclaw/openclaw.json`，docker 默认 `../runtime/config/openclaw.json`）的以下字段：

- `plugins.entries.worktool.enabled=true`
- `plugins.allow` 包含 `worktool`
- `channels.worktool.robotId`（来自 `ROBOT_ID`）
- `channels.worktool.bridgeBaseUrl`（默认 `https://api.worktool.ymdyes.cn`）
- `channels.worktool.webhookHost/webhookPort/webhookPath`

说明：

- 外网 IP/域名不写入插件配置；它用于你在上游（WorkTool）里配置回调地址。
- 回调地址通常是：`https://your-public-domain.example.com/wechat/webhook`
- 需要模型配置可用（OpenClaw provider 可调用），否则只能收消息不能出 AI 回复。

方式 4：源码目录安装（开发联调）

```bash
openclaw plugins install /absolute/path/openclaw-plugin-worktool
```

方式 5：发布包安装（给私有部署环境）

```bash
cd /absolute/path/openclaw-plugin-worktool
npm run release:local
openclaw plugins install ./dist/package
```

Tag 自动发布（上传 tgz 到 GitHub Release）：

```bash
git tag v0.2.1
git push origin v0.2.1
```

## 配置

最小配置示例（重点是 `robotId + webhookPort/webhookPath`）：

```json
{
  "plugins": {
    "entries": {
      "worktool": { "enabled": true, "config": {} }
    },
    "allow": ["worktool"]
  },
  "channels": {
    "worktool": {
      "enabled": true,
      "robotId": "893724599f7244febceeb66b03825677",
      "bridgeBaseUrl": "https://api.worktool.ymdyes.cn",
      "webhookHost": "0.0.0.0",
      "webhookPort": 18799,
      "webhookPath": "/wechat/webhook",
      "webhookToken": "optional-shared-secret"
    }
  }
}
```

`bridgeBaseUrl` 解析优先级：

1. `channels.worktool.accounts.<id>.bridgeBaseUrl`
2. `channels.worktool.bridgeBaseUrl`
3. 默认值 `https://api.worktool.ymdyes.cn`

nginx 映射示例：

- `https://your-public-domain.example.com/wechat/webhook`
- `-> 127.0.0.1:18799/wechat/webhook`

该配置下可直接连通。

## 模型配置（先做）

如果你是 Docker 方式运行 OpenClaw（推荐），请先在 `docker-compose.worktool.yml` 同级目录创建 `.env`，至少包含：

```dotenv
MODEL_ID=claw-primary
MODEL_BASE_URL=http://127.0.0.1:13030/v1
MODEL_API_KEY=dummy_key
MODEL_API_PROTOCOL=openai-completions
```

说明：

- `MODEL_BASE_URL` 指向你的模型网关（需能从容器内访问）。
- `MODEL_API_KEY` 按你的模型服务要求填写；若服务不校验可放占位值。
- 不配置模型时，插件可接收 webhook，但无法产出 AI 回复。

## 可视化管理页

插件会随 webhook 一起挂一个轻量管理页（默认）：

- `https://your-public-domain.example.com/wechat/admin?robotId=<robotId>`

功能：

- 查看当前 worktool 配置
- 在线修改 `robotId / bridgeBaseUrl / webhook*`
- 在线发送测试回调 payload

说明：

- 访问管理页需要鉴权（`?robotId=...` 或 `?token=...`）。
- 修改 `webhookHost/webhookPort` 后需要重启 OpenClaw 生效。

## 回调联调（curl）

### 1) 健康检查

```bash
curl -i https://your-public-domain.example.com/wechat/webhook
```

期望 `200` 且返回 `channel=worktool`。

### 2) 发送模拟消息（按 WorkTool 回调字段）

```bash
curl -X POST 'https://your-public-domain.example.com/wechat/webhook' \
  -H 'Content-Type: application/json' \
  -H 'x-worktool-token: 893724599f7244febceeb66b03825677' \
  -d '{
    "spoken": "你好啊",
    "rawSpoken": "@me 你好啊",
    "receivedName": "仑哥",
    "groupName": "测试群1",
    "groupRemark": "测试群1备注名",
    "roomType": "1",
    "atMe": true,
    "textType": "1",
    "fileBase64": ""
  }'
```

如果网关、模型、bridge 正常，小龙虾会通过 worktool bridge 回发到群备注名/群名（群聊）或 `receivedName`（单聊）。

## 推荐回调结构

建议上游尽量采用 Feishu 风格 envelope（字段信息量更完整），见文档：

- `docs/ARCHITECTURE-LARK-REFERENCE.md`

## License

[MIT](./LICENSE)
