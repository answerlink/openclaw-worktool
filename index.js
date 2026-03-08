import { emptyPluginConfigSchema } from "openclaw/plugin-sdk";
import { worktoolPlugin } from "./src/channel.js";

const plugin = {
  id: "worktool",
  name: "WorkTool",
  description: "WorkTool bridge channel plugin",
  configSchema: emptyPluginConfigSchema(),
  register(api) {
    api.registerChannel({ plugin: worktoolPlugin });
  },
};

export default plugin;
