// Where to find a headless Chromium, in priority order:
//
//   1. PUPPETEER_EXECUTABLE_PATH, when someone has pointed us at one;
//   2. /opt/pw-browsers/chromium, the fixed path in the dev sandbox image;
//   3. nothing, letting puppeteer resolve the copy its own installer fetched
//      into ~/.cache/puppeteer, which is what CI has.
//
// Hardcoding (2) as a default is what broke the design-web job: the path does
// not exist on a GitHub runner, and puppeteer fails on a configured path
// rather than falling back.

const fs = require('node:fs');

const SANDBOX_CHROMIUM = '/opt/pw-browsers/chromium';

function chromiumExecutable() {
  if (process.env.PUPPETEER_EXECUTABLE_PATH) return process.env.PUPPETEER_EXECUTABLE_PATH;
  if (fs.existsSync(SANDBOX_CHROMIUM)) return SANDBOX_CHROMIUM;
  return undefined;
}

/// Spreadable into puppeteer.launch(); omits executablePath entirely when
/// there is no explicit one to give.
function chromiumLaunchOptions() {
  const executablePath = chromiumExecutable();
  return executablePath ? { executablePath } : {};
}

module.exports = { chromiumExecutable, chromiumLaunchOptions };
