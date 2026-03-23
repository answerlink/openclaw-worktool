let runtime = null;

export function setWorktoolRuntime(next) {
  runtime = next;
}

export function getWorktoolRuntime() {
  if (!runtime) {
    throw new Error("worktool runtime not initialized");
  }
  return runtime;
}
