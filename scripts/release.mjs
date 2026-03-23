#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";

function parseArgs(argv) {
  const args = { bump: null, version: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--bump") args.bump = argv[i + 1];
    if (a === "--version") args.version = argv[i + 1];
  }
  return args;
}

function parseSemver(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v);
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) };
}

function bumpVersion(current, bumpType) {
  const ver = parseSemver(current);
  if (!ver) throw new Error(`invalid current version: ${current}`);
  if (bumpType === "major") return `${ver.major + 1}.0.0`;
  if (bumpType === "minor") return `${ver.major}.${ver.minor + 1}.0`;
  return `${ver.major}.${ver.minor}.${ver.patch + 1}`;
}

async function updatePackageVersion(nextVersion) {
  const pkgPath = resolve("package.json");
  const pkg = JSON.parse(await readFile(pkgPath, "utf8"));
  pkg.version = nextVersion;
  await writeFile(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
}

function run(cmd, args) {
  execFileSync(cmd, args, { stdio: "inherit" });
}

async function main() {
  const { bump, version } = parseArgs(process.argv.slice(2));
  if (bump && !["patch", "minor", "major"].includes(bump)) {
    throw new Error("invalid --bump, expected one of: patch|minor|major");
  }

  const pkg = JSON.parse(await readFile(resolve("package.json"), "utf8"));
  const current = pkg.version;
  let next = current;

  if (version) {
    if (!parseSemver(version)) throw new Error(`invalid --version: ${version}`);
    next = version;
  } else if (bump) {
    next = bumpVersion(current, bump);
  }

  if (next !== current) {
    await updatePackageVersion(next);
    console.log(`Version updated: ${current} -> ${next}`);
  } else {
    console.log(`Version unchanged: ${current}`);
  }

  run("npm", ["run", "release:local"]);
  console.log("Release artifacts are under dist/.");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
