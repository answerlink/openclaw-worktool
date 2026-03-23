#!/usr/bin/env node

import { mkdir, rm, cp, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(".");
const distDir = resolve(root, "dist");
const outDir = resolve(distDir, "package");

const filesToCopy = [
  "index.js",
  "openclaw.plugin.json",
  "README.md",
  "CHANGELOG.md",
  "DEPLOYMENT.md",
  "LICENSE",
];

async function copyIfExists(path) {
  await cp(resolve(root, path), resolve(outDir, path), { recursive: true });
}

async function main() {
  await rm(distDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });

  for (const item of filesToCopy) {
    await copyIfExists(item);
  }
  await copyIfExists("src");
  await copyIfExists("docs");

  const pkgPath = resolve(root, "package.json");
  const pkg = JSON.parse(await readFile(pkgPath, "utf8"));
  const outPkg = {
    name: pkg.name,
    version: pkg.version,
    description: pkg.description,
    type: pkg.type,
    files: pkg.files,
    engines: pkg.engines,
    openclaw: pkg.openclaw,
    license: "MIT",
  };
  await writeFile(resolve(outDir, "package.json"), JSON.stringify(outPkg, null, 2) + "\n");

  // Keep runtime payload lean: plugin runtime only needs JS files.
  await rm(resolve(outDir, "src", "channel.ts"), { force: true });
  await rm(resolve(outDir, "src", "inbound.ts"), { force: true });
  await rm(resolve(outDir, "src", "monitor.ts"), { force: true });
  await rm(resolve(outDir, "src", "runtime.ts"), { force: true });

  console.log(`Build complete: ${outDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
