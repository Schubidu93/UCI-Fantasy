// Waiver (Rangfolge und FAAB), freie Phase und Tausch: Anträge, Auswertung am Stichtag, Kader danach, Push-Nachrichten
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { as, rider, createUser, freshDb, type Db } from "./db";

let db: Db;
let alice: string, bob: string;
const Y = new Date().getFullYear();
const day = (n: number) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);

beforeEach(async () => {
  db = await freshDb();
  alice = await createUser(db, "alice");
  bob = await createUser(db, "bob");
  for (let n = 1; n <= 6; n++) await rider(db, n, `Fahrer ${n}`);
});
afterEach(async () => { await db.end(); });

async function league(settings: Record<string, unknown>) {
  await as(db, alice);
  const id = (await db.one("select create_league('Liga', 'Team Alice', $1) id", [{ gender: "men", draft_mode: "offline", roster_size: 5, ...settings }])).id;
  const code = (await db.one("select invite_code from leagues where id = $1", [id])).invite_code;
  await as(db, bob);
  await db.query("select join_league($1, 'Team Bob')", [code]);
  await as(db, alice);
  const m = await db.all("select id, team_name from managers where league_id = $1", [id]);
  const L = { id, alice: m.find((x) => x.team_name === "Team Alice").id, bob: m.find((x) => x.team_name === "Team Bob").id };
  for (const [mgr, a] of [[L.alice, "r-1"], [L.alice, "r-2"], [L.bob, "r-3"], [L.bob, "r-4"]]) {
    await db.query("insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on) values ($1, $2, $3, 10, 'offline', $4)",
      [id, mgr, a, `${Y}-01-01`]);
  }
  // Kader nur teilweise gefüllt (2 von 5) – reicht für die Tests, Abgaben sind trotzdem angegeben
  await db.query("update leagues set status = 'active' where id = $1", [id]);
  const md = (await db.one("select upsert_matchday($1, null, 'Spieltag 1', $2, $3) id", [id, day(3), day(20)])).id;
  return { ...L, md };
}
const roster = async (mgr: string) => (await db.all(
  "select athlete_id from roster_entries where manager_id = $1 and released_on is null order by athlete_id", [mgr])).map((r) => r.athlete_id);
// Waiver-Frist erreicht (Stichtag selbst noch offen) → Auswertung wie beim Öffnen der App
const runWaivers = async (md: string) => {
  await db.query("update matchdays set waiver_deadline = now() where id = $1", [md]);
  await db.query("select process_due(null)");
};

describe("Waiver", () => {
  it("Rangfolge: beide wollen denselben Fahrer – einer bekommt ihn, der andere seinen zweiten Wunsch", async () => {
    const L = await league({ waiver_mode: "priority" });
    await db.query("select submit_waiver($1, 'r-5', 'r-1')", [L.id]);
    await as(db, bob);
    await db.query("select submit_waiver($1, 'r-5', 'r-3')", [L.id]);
    await db.query("select submit_waiver($1, 'r-6', 'r-3')", [L.id]);
    await runWaivers(L.md);
    const claims = await db.all("select m.team_name, add_athlete, status from waiver_claims c join managers m on m.id = c.manager_id order by m.team_name, add_athlete");
    const wonFive = claims.find((c) => c.add_athlete === "r-5" && c.status === "won");
    expect(wonFive).toBeTruthy();
    expect(claims.filter((c) => c.status === "won")).toHaveLength(2);   // Verlierer bekommt seinen zweiten Wunsch
    expect(await roster(L.alice)).toHaveLength(2);
    expect(await roster(L.bob)).toHaveLength(2);
    const all = [...await roster(L.alice), ...await roster(L.bob)];
    expect(new Set(all).size).toBe(4);   // kein Fahrer doppelt
    expect((await db.one("select waivers_done from matchdays where id = $1", [L.md])).waivers_done).toBe(true);
  });

  it("FAAB: höheres Gebot gewinnt, Budget sinkt", async () => {
    const L = await league({ waiver_mode: "faab" });
    const before = (await db.one("select budget_left from managers where id = $1", [L.bob])).budget_left;
    await db.query("select submit_waiver($1, 'r-5', 'r-1', 3)", [L.id]);
    await as(db, bob);
    await db.query("select submit_waiver($1, 'r-5', 'r-3', 7)", [L.id]);
    await runWaivers(L.md);
    expect(await roster(L.bob)).toEqual(["r-4", "r-5"]);
    expect(await roster(L.alice)).toEqual(["r-1", "r-2"]);
    expect((await db.one("select budget_left from managers where id = $1", [L.bob])).budget_left).toBe(before - 7);
  });

  it("freie Phase nach der Waiver-Runde: sofort tauschen, gilt ab dem Spieltag", async () => {
    const L = await league({ transfer_mode: "waiver_free" });
    await runWaivers(L.md);
    expect((await db.one("select transfer_phase($1) p", [L.id])).p.phase).toBe("free");
    await db.query("select free_move($1, 'r-6', 'r-2')", [L.id]);
    expect(await roster(L.alice)).toEqual(["r-1", "r-6"]);
    await as(db, bob);
    await expect(db.query("select free_move($1, 'r-6', 'r-4')", [L.id])).rejects.toThrow(/schon vergeben/);
  });

  it("nur reine Waiver-Liga: keine freie Phase", async () => {
    const L = await league({ transfer_mode: "waiver" });
    await runWaivers(L.md);
    expect((await db.one("select transfer_phase($1) p", [L.id])).p.phase).toBe("waiver");
    await expect(db.query("select free_move($1, 'r-6', 'r-2')", [L.id])).rejects.toThrow(/keine freie Phase/);
  });

  it("Tausch: Push an beide Seiten bei Angebot, Zusage und Ausführung", async () => {
    const L = await league({});
    for (const u of [alice, bob]) await db.query("insert into push_subscriptions (endpoint, user_id, p256dh, auth) values ($1, $2, 'k', 'a')", [String(u), u]);
    const msgs = async (u: string) => (await db.all("select title, body from notifications where user_id = $1 order by id", [u])).map((m) => m.title);
    const id = (await db.one("select propose_trade($1, $2, '{r-1}', '{r-3}') id", [L.id, L.bob])).id;
    expect(await msgs(bob)).toEqual(["🔁 Neues Tauschangebot"]);
    await as(db, bob);
    await db.query("select respond_trade($1, true)", [id]);
    expect(await msgs(alice)).toEqual(["✅ Tausch angenommen"]);
    // Vetofrist vorbei, Stichtag erreicht → Tausch wird ausgeführt
    await db.query("update trades set accepted_at = now() - interval '2 days' where id = $1", [id]);
    await db.query("update matchdays set deadline = now(), waiver_deadline = now() where id = $1", [L.md]);
    await db.query("select process_due(null)");
    expect(await roster(L.alice)).toEqual(["r-2", "r-3"]);
    expect((await msgs(alice)).at(-1)).toBe("✅ Tausch ausgeführt");
    expect((await msgs(bob)).at(-1)).toBe("✅ Tausch ausgeführt");
    const body = (await db.one("select body from notifications where user_id = $1 order by id desc limit 1", [bob])).body;
    expect(body).toBe("Neu im Kader: Fahrer 1 · abgegeben: Fahrer 3");
  });

  it("Tausch zurückgezogen: Empfänger bekommt Push", async () => {
    const L = await league({});
    await db.query("insert into push_subscriptions (endpoint, user_id, p256dh, auth) values ('b', $1, 'k', 'a')", [bob]);
    const id = (await db.one("select propose_trade($1, $2, '{r-1}', '{r-3}') id", [L.id, L.bob])).id;
    await db.query("select cancel_trade($1)", [id]);
    expect((await db.one("select title from notifications where user_id = $1 order by id desc limit 1", [bob])).title).toBe("↩️ Tauschangebot zurückgezogen");
  });
});
