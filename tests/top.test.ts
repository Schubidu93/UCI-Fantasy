// Rennen → Top-Ergebnisse: meiste Punkte im Zeitraum, je Team nur Ergebnisse, die dem Team Punkte gebracht haben
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { as, rider, createUser, freshDb, type Db } from "./db";

let db: Db;
const day = (n: number) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);

beforeEach(async () => { db = await freshDb(); });
afterEach(async () => { await db.end(); });

describe("Top-Ergebnisse", () => {
  it("meiste Punkte im Zeitraum, je Team nur gezählte Ergebnisse", async () => {
    const alice = await createUser(db, "alice"), bob = await createUser(db, "bob");
    for (let n = 1; n <= 3; n++) await rider(db, n, `Fahrer ${n}`);
    await as(db, alice);
    const L = (await db.one("select create_league('Liga', 'Team Alice', $1) id", [{ gender: "men", draft_mode: "offline", roster_size: 5, scoring_mode: "full" }])).id;
    const code = (await db.one("select invite_code from leagues where id = $1", [L])).invite_code;
    await as(db, bob);
    await db.query("select join_league($1, 'Team Bob')", [code]);
    await as(db, alice);
    const m = await db.all("select id, team_name from managers where league_id = $1", [L]);
    const A = m.find((x) => x.team_name === "Team Alice").id, B = m.find((x) => x.team_name === "Team Bob").id;
    // r-1 bei Alice erst ab gestern: das Ergebnis von vor 3 Tagen zählt nicht für sie
    await db.query("insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on) values ($1, $2, 'r-1', 1, 'offline', $3)", [L, A, day(-1)]);
    await db.query("update leagues set status = 'active' where id = $1", [L]);
    const md = (await db.one("select upsert_matchday($1, null, 'S', $2, $3) id", [L, day(2), day(20)])).id;
    await db.query("update matchdays set starts_on = $2, deadline = now() - interval '1 hour' where id = $1", [md, day(-5)]);
    await db.query(`insert into results (athlete_id, competition_id, label, result_date, rank, points) values
      ('r-1', 'heute', 'result', $1, 2, 100), ('r-1', 'frueher', 'result', $2, 1, 150), ('r-2', 'heute', 'result', $1, 1, 200)`, [day(0), day(-3)]);
    const top = async (mgr: string | null) => (await db.all("select athlete_id, points::float p from top_results('men', $1, $2, 100, $3, $4)",
      [day(-10), day(0), L, mgr])).map((r) => `${r.athlete_id} ${r.p}`);
    expect(await top(null)).toEqual(["r-2 200", "r-1 150", "r-1 100"]);
    expect(await top(A)).toEqual(["r-1 100"]);
    expect(await top(B)).toEqual([]);
  });
});
