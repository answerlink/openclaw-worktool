# openclaw-plugin-worktool

OpenClaw 的 WorkTool 渠道插件，支持：

- 出站：将 OpenClaw 回复发送到微信（经 WorkTool bridge）。
- 入站：接收 WorkTool webhook 回调并路由到小龙虾 Agent。

## 安装

方式 1：源码目录安装（开发联调）

```bash
openclaw plugins install /absolute/path/openclaw-plugin-worktool
```

方式 2：发布包安装（推荐给部署环境）

```bash
cd /absolute/path/openclaw-plugin-worktool
npm run release:local
openclaw plugins install ./dist/package
```

如果需要分发单文件包：

```bash
cd /absolute/path/openclaw-plugin-worktool
npm run release:local
ls -lh dist/*.tgz
```

自动升级版本并打包：

```bash
# 0.2.0 -> 0.2.1
npm run release -- --bump patch
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
- `-> 10.21.8.6:18799/wechat/webhook`

该配置下可直接连通。

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
