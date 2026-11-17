// Oberflächentest (beide Apps gleich): Beispieldaten anlegen, Supabase-Nachbau und App starten und dann in der
// iPhone-Ansicht jeden Bereich, jeden Unterreiter, jeden Admin-Bereich und ein Profil öffnen. Jeder JavaScript-Fehler
// und jede fehlgeschlagene Anfrage lässt den Test scheitern. Die Seiten werden über die Navigation der App gefunden.
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createServer, type Server } from "node:http";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { extname, join } from "node:path";
import { chromium, devices, type Browser, type Page } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const ROOT = join(import.meta.dirname, "..", "..");
const ADMIN_URL = process.env.TEST_DATABASE_URL ?? "postgres://postgres@localhost:54329/postgres?host=/tmp/fa-pg";
const DB = "ui_smoke";
const API_PORT = 54331, WEB_PORT = 8131;
const dbUrl = () => { const u = new URL(ADMIN_URL); u.pathname = `/${DB}`; return u.toString(); };
const TYPES: Record<string, string> = { ".js": "text/javascript", ".html": "text/html", ".css": "text/css", ".svg": "image/svg+xml",
  ".png": "image/png", ".json": "application/json", ".webmanifest": "application/manifest+json" };

let api: ChildProcess, web: Server, browser: Browser, page: Page, userId: string;
const errors: string[] = [];

beforeAll(async () => {
  userId = execFileSync("npx", ["tsx", "tests/ui/seed.ts"], { cwd: ROOT, env: { ...process.env, ADMIN_URL, DB }, encoding: "utf8" }).trim().split("\n").pop()!;
  api = spawn("npx", ["tsx", "tests/ui/mock-api.ts"], { cwd: ROOT, env: { ...process.env, DATABASE_URL: dbUrl(), PORT: String(API_PORT) }, stdio: "ignore" });
  // App ausliefern; config.js zeigt auf den Nachbau (die echte config.js wird nie eingecheckt)
  web = createServer((req, res) => {
    const path = decodeURIComponent((req.url ?? "/").split("?")[0]);
    if (path === "/config.js") { res.setHeader("content-type", TYPES[".js"]); return res.end(`export default { url: "http://localhost:${API_PORT}", anonKey: "test" };`); }
    const file = join(ROOT, "web", path === "/" ? "index.html" : path);
    if (!file.startsWith(join(ROOT, "web")) || !existsSync(file)) { res.statusCode = 404; return res.end(); }
    res.setHeader("content-type", TYPES[extname(file)] ?? "application/octet-stream");
    res.end(readFileSync(file));
  }).listen(WEB_PORT);
  for (let i = 0; i < 50; i++) {   // warten, bis der Nachbau antwortet
    try { await fetch(`http://localhost:${API_PORT}/rest/v1/`); break; } catch { await new Promise((r) => setTimeout(r, 200)); }
  }
  browser = await chromium.launch();
  const ctx = await browser.newContext({ ...devices["iPhone 13"] });
  const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const session = { access_token: `${b64({ alg: "none" })}.${b64({ sub: userId, role: "authenticated", exp: 9999999999 })}.x`,
    refresh_token: "r", token_type: "bearer", expires_in: 9e9, expires_at: 9999999999, user: { id: userId, aud: "authenticated", role: "authenticated" } };
  await ctx.addInitScript((s) => localStorage.setItem("sb-localhost-auth-token", s), JSON.stringify(session));
  page = await ctx.newPage();
  page.on("pageerror", (e) => errors.push(`Fehler: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error" && !/WebSocket|realtime/.test(m.text())) errors.push(`Konsole: ${m.text()}`); });
  page.on("response", (r) => { if (r.status() >= 400 && !r.url().includes("/realtime/")) errors.push(`HTTP ${r.status()}: ${r.url()}`); });
}, 120_000);

afterAll(async () => {
  await browser?.close();
  api?.kill();
  web?.close();
});

const open = async (hash: string) => {
  errors.length = 0;
  await page.goto(`http://localhost:${WEB_PORT}/#${hash}`);
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(300);
  return page.innerText("body");
};
const links = (sel: string) => page.$$eval(sel, (as) => as.map((a) => (a as HTMLAnchorElement).hash.slice(1)));

describe("Oberfläche (iPhone)", () => {
  it("Ligenliste und „Liga anlegen“", async () => {
    expect(await open("/")).toContain("Meine Ligen");
    await page.click('button:has-text("Liga anlegen")');
    for (const mode of ["snake", "live", "blind", "offline"]) await page.selectOption('select:has(option[value="offline"])', mode);
    expect(errors).toEqual([]);
  });

  it("alle Bereiche, Unterreiter und Admin-Bereiche öffnen ohne Fehler", async () => {
    await open("/");
    const league = (await links('a[href^="#/league/"]'))[0];
    expect(league).toBeTruthy();
    await open(league);
    const seen = new Set<string>();
    const visit = async (hash: string) => {
      if (seen.has(hash)) return;
      seen.add(hash);
      const text = await open(hash);
      expect.soft(errors, hash).toEqual([]);
      expect.soft(text.length, hash).toBeGreaterThan(100);
    };
    for (const main of await links(".mainnav a")) {
      await visit(main);
      for (const sub of await links(".subnav a")) await visit(sub);
    }
    for (const a of await links('a[href*="/admin/"]')) await visit(a);
    expect(seen.size).toBeGreaterThan(15);
  }, 120_000);

  it("Profil einer Person öffnet sich", async () => {
    await open("/");
    const league = (await links('a[href^="#/league/"]'))[0];
    const main = (await (async () => { await open(league); return links(".mainnav a"); })())[2];   // dritter Bereich: Athleten bzw. Fahrer
    await open(main);
    await page.click(".rider-name");
    await page.waitForTimeout(800);
    expect(await page.locator(".modal, [role=dialog]").count()).toBeGreaterThan(0);
    expect(errors).toEqual([]);
  });
});
