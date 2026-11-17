// „Datenbank einrichten“ spielt das Schema bei jedem Merge erneut ein – mit echten Daten darf dabei nichts verloren gehen.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, expect, it } from "vitest";
import { freshDb, schemaSql, type Db } from "./db";

const ROOT = join(import.meta.dirname, "..");
const TABLES = ["leagues", "managers", "roster_entries", "matchdays", "results", "waiver_claims", "trades", "notifications"];
let db: Db;
beforeAll(async () => { db = await freshDb(); });
afterAll(async () => { await db.end(); });

const counts = async () => Object.fromEntries(await Promise.all(TABLES.map(async (t) => [t, Number((await db.one(`select count(*) n from ${t}`)).n)])));

it("Schema erneut einspielen erhält alle Daten", async () => {
  await db.query(readFileSync(join(ROOT, "tests/sql/fixtures.sql"), "utf8"));
  await db.query(`insert into matchdays (league_id, name, starts_on, ends_on, deadline)
                  values (test_support.league(), 'Spieltag', current_date + 10, current_date + 20, now() + interval '9 days')`);
  await db.query(`insert into notifications (user_id, title) values (test_support.user_id(1), 'Hallo')`);
  const before = await counts();
  const budgets = await db.all("select id, budget_left from managers order by id");
  await db.query(schemaSql());
  expect(await counts()).toEqual(before);
  expect(await db.all("select id, budget_left from managers order by id")).toEqual(budgets);
});
