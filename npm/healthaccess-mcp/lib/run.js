"use strict";
// Finds the prebuilt binary that npm installed for this platform (one of the
// optionalDependencies) and runs it with the same arguments. stdio is inherited
// untouched: healthaccess-mcp speaks MCP over stdin/stdout.

const { spawn } = require("node:child_process");

const PACKAGES = {
  "darwin-arm64": "healthaccess-mcp-darwin-arm64",
  "darwin-x64": "healthaccess-mcp-darwin-x64",
  "linux-arm64": "healthaccess-mcp-linux-arm64",
  "linux-x64": "healthaccess-mcp-linux-x64",
  "win32-x64": "healthaccess-mcp-win32-x64",
};

function fail(message) {
  process.stderr.write(`healthaccess-mcp: ${message}\n`);
  process.exit(1);
}

function binaryPath(name) {
  const override = name === "healthaccess-mcp" ? process.env.HEALTHACCESS_MCP_BINARY : process.env.HEALTHACCESS_CLI_BINARY;
  if (override) return override;
  const key = `${process.platform}-${process.arch}`;
  const pkg = PACKAGES[key];
  if (!pkg) {
    fail(
      `there is no prebuilt binary for ${key} (prebuilt: ${Object.keys(PACKAGES).join(", ")}). ` +
        "Build it from source instead: https://healthaccessmcp.com/docs/install",
    );
  }
  const file = process.platform === "win32" ? `${name}.exe` : name;
  try {
    return require.resolve(`${pkg}/bin/${file}`);
  } catch {
    fail(
      `the package ${pkg} is missing; npm skips it when optional dependencies are turned off. ` +
        `Install it with: npm install -g healthaccess-mcp --include=optional`,
    );
  }
}

function run(name) {
  const child = spawn(binaryPath(name), process.argv.slice(2), { stdio: "inherit", windowsHide: true });
  const forward = (signal) => {
    if (!child.killed) child.kill(signal);
  };
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => forward(signal));
  child.on("error", (err) => fail(`could not start ${name}: ${err.message}`));
  child.on("exit", (code, signal) => {
    if (signal) {
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
    } else {
      process.exit(code ?? 1);
    }
  });
}

module.exports = { run, binaryPath, PACKAGES };
