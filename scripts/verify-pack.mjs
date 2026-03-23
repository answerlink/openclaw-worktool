#!/usr/bin/env node

import { readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";

const distDir = resolve("dist");
const requiredEntries = [
  "package/package.json",
  "package/openclaw.plugin.json",
  "package/index.js",
  "package/src/channel.js",
  "package/src/inbound.js",
  "package/src/monitor.js",
  "package/src/runtime.js",
];

async function pickLatestTgz() {
  const files = await readdir(distDir);
  const tgz = files.filter((f) => f.endsWith(".tgz")).sort();
  if (tgz.length === 0) {
    throw new Error("no .tgz artifact found under dist/");
  }
  return resolve(distDir, tgz[tgz.length - 1]);
}

async function main() {
  const tgz = await pickLatestTgz();
  const listing = execFileSync("tar", ["-tzf", tgz], { encoding: "utf8" })
    .split("\n")
    .map((x) => x.trim())
    .filter(Boolean);

  const missing = requiredEntries.filter((entry) => !listing.includes(entry));
  if (missing.length > 0) {
    throw new Error(`pack validation failed, missing entries:\n${missing.join("\n")}`);
  }

  console.log(`Pack validation passed: ${tgz}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
