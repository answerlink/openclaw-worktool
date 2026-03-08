# openclaw-plugin-worktool

一个简单易用的 OpenClaw 渠道插件：把 OpenClaw 的回复转发到 WorkTool 机器人。

## 安装

把仓库放到 OpenClaw 的扩展目录（推荐软链接）：

```bash
ln -s /absolute/path/openclaw-plugin-worktool /absolute/path/to/openclaw/extensions/worktool
```

## 配置

在 `openclaw.json` 里加入下面最小配置即可（默认单机器人，不做多账号）：

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
      "robotId": "your_robot_id",
      "bridgeBaseUrl": "http://host.docker.internal:3000"
    }
  },
  "gateway": {
    "auth": {
      "mode": "token",
      "token": "your_gateway_token"
    }
  }
}
```

可用以下命令生成 token：

```bash
openssl rand -hex 32
```

## 验证

重启 OpenClaw 后，在渠道里选择 `WorkTool`，给任意联系人发送一条测试消息即可。

## License

[MIT](./LICENSE)
