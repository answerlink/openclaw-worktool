# WorkTool 插件发布与安装

本文档用于把 `openclaw-plugin-worktool` 做成可分发安装包（参考 `openclaw-lark` 的发布方式）。

## 0. 用户一键安装

latest：

```bash
ROBOT_ID=wc11a curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

CLI 模式（需要本机有 `openclaw` 命令）：

```bash
ROBOT_ID=wc11a curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

指定版本：

```bash
ROBOT_ID=wc11a VERSION=0.2.1 curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install-docker.sh | bash
```

CLI 模式指定版本：

```bash
ROBOT_ID=wc11a VERSION=0.2.1 curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-plugin-worktool/main/scripts/install.sh | bash
```

clone 后本地一键安装（Docker 推荐）：

```bash
git clone https://github.com/answerlink/openclaw-plugin-worktool.git
cd openclaw-plugin-worktool
ROBOT_ID=wc11a bash scripts/install-local.sh
```

`install-local.sh` 默认使用 docker 模式（等价 `scripts/install-local-docker.sh`）。

如需显式指定 docker 配置路径：

```bash
ROBOT_ID=wc11a \
OPENCLAW_CONFIG=/path/to/runtime/config/openclaw.json \
COMPOSE_FILE=/path/to/docker-compose.worktool.yml \
bash scripts/install-local-docker.sh
```

clone 后本地一键安装（非 Docker，可选）：

```bash
ROBOT_ID=wc11a bash scripts/install-local-native.sh
```

Docker 用户安装前，请先准备模型 `.env`（与 compose 文件同级）：

```dotenv
MODEL_ID=claw-primary
MODEL_BASE_URL=http://127.0.0.1:13030/v1
MODEL_API_KEY=dummy_key
MODEL_API_PROTOCOL=openai-completions
```

## 1. 发布前检查

- 确认 `index.js` / `src/*.js` 为最新运行代码。
- 确认配置项约定稳定：
  - WorkTool 地址仅 `channels.worktool.bridgeBaseUrl`
  - webhook 鉴权支持 `x-worktool-token` 或 `?robotId=...`
- 在 `package.json` 更新版本号（遵循 semver）。

## 2. 构建发布目录

```bash
cd /absolute/path/openclaw-plugin-worktool
npm run build
```

产物目录：

- `dist/package/`
  - `package.json`（精简发布版）
  - `openclaw.plugin.json`
  - `index.js`
  - `src/*.js`
  - `README.md` / `DEPLOYMENT.md` / `docs/`

## 3. 生成 tgz 发布包

```bash
cd /absolute/path/openclaw-plugin-worktool
npm run release:local
```

产物：

- `dist/package/`（目录安装）
- `dist/openclaw-plugin-worktool-<version>.tgz`（单文件分发）

如需自动升级版本后发布：

```bash
# patch: 0.2.0 -> 0.2.1
npm run release -- --bump patch

# 或直接指定版本
npm run release -- --version 0.3.0
```

## 3.1 GitHub 自动发布（Tag）

仓库内置了工作流 `release-tgz.yml`：

- 当你 push tag `vX.Y.Z` 时，自动：
  - 校正版本为 `X.Y.Z`
  - 构建并打包
  - 运行包结构校验
  - 在 GitHub Release 上传 `dist/*.tgz`

示例：

```bash
git tag v0.2.1
git push origin v0.2.1
```

## 4. 安装方式

目录安装：

```bash
openclaw plugins install /absolute/path/openclaw-plugin-worktool/dist/package
```

tgz 安装：

```bash
openclaw plugins install /absolute/path/openclaw-plugin-worktool/dist/openclaw-plugin-worktool-<version>.tgz
```

## 5. 最小验收

1. 健康检查：

```bash
curl -i http://127.0.0.1:18799/wechat/webhook
```

2. Header 鉴权：

```bash
curl -X POST 'http://127.0.0.1:18799/wechat/webhook' \
  -H 'Content-Type: application/json' \
  -H 'x-worktool-token: <robotId>' \
  -d '{"spoken":"ping","rawSpoken":"@me ping","receivedName":"u","groupName":"g","groupRemark":"","roomType":"1","atMe":true,"textType":"1","fileBase64":""}'
```

3. Query 鉴权：

```bash
curl -X POST 'http://127.0.0.1:18799/wechat/webhook?robotId=<robotId>' \
  -H 'Content-Type: application/json' \
  -d '{"spoken":"ping","rawSpoken":"@me ping","receivedName":"u","groupName":"g","groupRemark":"","roomType":"1","atMe":true,"textType":"1","fileBase64":""}'
```

期望：快速返回 `200` 且含 `queued=true`，随后异步回发微信消息。
