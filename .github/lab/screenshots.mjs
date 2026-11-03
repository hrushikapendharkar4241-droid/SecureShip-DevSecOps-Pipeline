// Screenshots of a finished lab run: Jenkins stage view, the rollback console, SonarQube,
// the deployed ShopPilot, evidence reports and the ledger tamper demo.
//   node screenshots.mjs <repo-root> <out-dir>
// Every shot is best-effort: a missing page is logged and skipped, never fatal.
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, out] = process.argv.slice(2);
const ev = path.join(root, "demo-evidence");
const env = Object.fromEntries(
  fs.readFileSync(path.join(root, "ci/.env"), "utf8").split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
);
const scenarios = fs.existsSync(path.join(ev, "scenarios.tsv"))
  ? fs.readFileSync(path.join(ev, "scenarios.tsv"), "utf8").trim().split("\n").filter(Boolean).map((l) => l.split("\t"))
  : [];
const build = (key) => scenarios.find((r) => r[0] === key)?.[1];

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
let page;   // a fresh tab per shot (a failed load must not break the next one); cookies are shared
const shot = async (name, opts = {}) => {
  await page.screenshot({ path: path.join(out, name), ...opts });
  console.log("saved", name);
};
const attempt = async (name, fn) => {
  page = await ctx.newPage();
  try { await fn(); } catch (e) { console.log(`skipped ${name}: ${String(e.message).split("\n")[0]}`); }
  await page.close();
};

// Jenkins: log in, stage view of all runs side by side
await attempt("jenkins", async () => {
  await page.goto("http://localhost:8080/login");
  await page.fill("#j_username", env.JENKINS_ADMIN_ID);
  await page.fill('input[name="j_password"]', env.JENKINS_ADMIN_PASSWORD);
  await Promise.all([page.waitForLoadState("networkidle"), page.click('button[type="submit"]')]);
  await page.goto("http://localhost:8080/job/SecureShip/");
  await page.waitForTimeout(6000);
  await shot("jenkins-stage-view.png", { fullPage: true });
});

// The rollback, as Jenkins printed it
for (const [key, file] of [["5", "rollback-console.png"], ["5b", "rollback-unhealthy-console.png"]]) {
  const n = build(key);
  if (!n) continue;
  await attempt(file, async () => {
    await page.goto(`http://localhost:8080/job/SecureShip/${n}/console`);
    await page.getByText("ROLLING BACK").first().scrollIntoViewIfNeeded();
    await page.evaluate(() => window.scrollBy(0, -300));
    await shot(file);
  });
}

// SonarQube project dashboard
await attempt("sonarqube", async () => {
  await page.goto("http://localhost:9000/sessions/new");
  await page.fill("#login", "admin");
  await page.fill("#password", env.SONAR_ADMIN_PASSWORD);
  await Promise.all([page.waitForLoadState("networkidle"), page.click('button[type="submit"]')]);
  await page.goto("http://localhost:9000/dashboard?id=shoppilot");
  await page.waitForTimeout(6000);
  await shot("sonarqube-dashboard.png");
});

// ShopPilot as deployed by the pipeline
await attempt("shoppilot", async () => {
  await page.goto("http://localhost:8088/");
  await page.waitForTimeout(4000);
  await shot("shoppilot-deployed.png");
});

// Evidence reports ("release passports")
for (const [key, file] of [["1", "evidence-deployed.png"], ["2", "evidence-blocked-vulnerability.png"],
                           ["4", "evidence-blocked-secret.png"], ["5", "evidence-rolled-back.png"]]) {
  const n = build(key);
  const html = n && path.join(ev, n, "evidence.html");
  if (!html || !fs.existsSync(html)) continue;
  await attempt(file, async () => {
    await page.goto(pathToFileURL(html).href);
    await shot(file, { fullPage: true });
  });
}

// Terminal output of the tamper demos
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
for (const [txt, file] of [["tamper.txt", "ledger-tamper-detection.png"], ["append-only.txt", "anchor-append-only.png"]]) {
  const p = path.join(ev, txt);
  if (!fs.existsSync(p)) continue;
  await attempt(file, async () => {
    const body = esc(fs.readFileSync(p, "utf8"))
      .replace(/^(.*(✘|FAILED|missing from the ledger|modified).*)$/gm, '<span class="bad">$1</span>')
      .replace(/^(.*(✔|ledger OK|blocked).*)$/gm, '<span class="ok">$1</span>')
      .replace(/^(━━━.*)$/gm, '<span class="hdr">$1</span>');
    await page.setContent(`<html><body style="margin:0;background:#0d1117">
      <pre style="font:14px/1.5 'DejaVu Sans Mono',monospace;color:#c9d1d9;padding:24px;white-space:pre-wrap">${body}</pre>
      <style>.bad{color:#ff7b72}.ok{color:#7ee787}.hdr{color:#d2a8ff;font-weight:bold}</style></body></html>`);
    await shot(file, { fullPage: true });
  });
}

await browser.close();
