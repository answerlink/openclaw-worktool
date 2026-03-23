import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { emptyPluginConfigSchema } from "openclaw/plugin-sdk";
import { worktoolPlugin } from "./src/channel.js";
import { setWorktoolRuntime } from "./src/runtime.js";

const plugin = {
  id: "worktool",
  name: "WorkTool",
  description: "WorkTool bridge channel plugin",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    setWorktoolRuntime(api.runtime);
    api.registerChannel({ plugin: worktoolPlugin });
  },
};

export default plugin;
