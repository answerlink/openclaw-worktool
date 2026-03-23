import type { PluginRuntime } from "openclaw/plugin-sdk";

let runtime: PluginRuntime | null = null;

export function setWorktoolRuntime(next: PluginRuntime) {
  runtime = next;
}

export function getWorktoolRuntime(): PluginRuntime {
  if (!runtime) {
    throw new Error("worktool runtime not initialized");
  }
  return runtime;
}
