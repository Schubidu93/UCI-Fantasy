// Testdatenbank für den Oberflächentest: Schema + erfundene Fahrer, Rennen mit Ergebnislisten,
// eine laufende Männer-Liga mit drei Teams.
//   ADMIN_URL=postgres://…/postgres DB=uci_ui npx tsx tests/ui/seed.ts   → gibt die Nutzer-ID von „alice“ aus
import { readFileSync } from "node:fs";
import { join } from "node:path";
import pg from "pg";

const ROOT = join(import.meta.dirname, "..", "..");
const ADMIN_URL = process.env.ADMIN_URL ?? "postgres://postgres@localhost:54329/postgres?host=/tmp/fa-pg";
const DB = process.env.DB ?? "uci_ui";
const Y = new Date().getFullYear();
const day = (n: number) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);

const a = new pg.Client({ connectionString: ADMIN_URL });
await a.connect();
await a.query(`drop database if exists ${DB} with (force)`);
await a.query(`create database ${DB}`);
await a.end();
const u = new URL(ADMIN_URL);
u.pathname = `/${DB}`;
const db = new pg.Client({ connectionString: u.toString() });
await db.connect();
await db.query("set client_min_messages = warning");
for (const f of ["tests/supabase-stub.sql", "supabase/schema.sql"]) await db.query(readFileSync(join(ROOT, f), "utf8"));

// Erfundene Fahrer: [Name, Nation, Team, UCI-Punkte]
const RIDERS: [string, string, string, number][] = [
  ["Tim ADLER", "GER", "Team Nordwind", 5200], ["Luca BIANCHI", "ITA", "Squadra Azzurra", 4800], ["Jonas BERG", "NOR", "Fjord Racing", 4500],
  ["Pierre DUBOIS", "FRA", "Équipe Soleil", 4300], ["Max WEBER", "GER", "Team Nordwind", 3900], ["Sam CLARKE", "GBR", "Union Cycling", 3700],
  ["Diego RUIZ", "ESP", "Equipo Sierra", 3500], ["Jan DE VRIES", "NED", "Polder Pro", 3300], ["Felix KOCH", "GER", "Alpen Velo", 3100],
  ["Marco ROSSI", "ITA", "Squadra Azzurra", 2900], ["Erik LUND", "DEN", "Fjord Racing", 2700], ["Hugo MARTIN", "FRA", "Équipe Soleil", 2500],
  ["Ben SCHULZ", "GER", "Alpen Velo", 2300], ["Tom BAKER", "GBR", "Union Cycling", 2100], ["Pablo GARCIA", "ESP", "Equipo Sierra", 1900],
  ["Lars JANSEN", "NED", "Polder Pro", 1700], ["Nico WAGNER", "GER", "Team Nordwind", 1500], ["Paolo CONTI", "ITA", "Squadra Azzurra", 1300],
];
const slugs: string[] = [];
let rank = 0;
for (const [name, nation, team, pts] of RIDERS) {
  const slug = `uci-${100000 + ++rank}`;
  slugs.push(slug);
  await db.query(`insert into riders (pcs_slug, name, gender, nation, team, uci_rank, ranking_points, birth_date)
                  values ($1, $2, 'men', $3, $4, $5, $6, $7)`, [slug, name, nation, team, rank, pts, `${1993 + (rank % 9)}-0${1 + (rank % 9)}-15`]);
}

// Rennen mit Ergebnissen dieses Jahres: Eintagesrennen und eine Rundfahrt mit Etappen und Gesamtwertung
const RACES: [string, string, string, string, number][] = [
  [`frühjahrsklassiker/${Y}`, "Frühjahrsklassiker", "1.UWT", "BEL", -60],
  [`bergrundfahrt/${Y}`, "Bergrundfahrt", "2.UWT", "ITA", -30],
  [`herbstpreis/${Y}`, "Herbstpreis", "1.Pro", "GER", -3],
];
let ev = 900;
for (const [slug, name, cls, country, off] of RACES) {
  await db.query(`insert into races (pcs_slug, name, gender, start_date, end_date, uci_class, country, season, dataride_id)
                  values ($1, $2, 'men', $3, $4, $5, $6, $7, $8)`, [slug, name, day(off), day(off + (cls.startsWith("2.") ? 2 : 0)), cls, country, Y, 50000 + ev++]);
}
const result = async (race: string, stage: string | null, eventName: string, date: string, label: string, rows: [number, number][]) => {
  await db.query("insert into race_events (id, race_slug, stage_name, stage_no, event_name, event_date, winner) values ($1, $2, $3, $4, $5, $6, $7)",
    [++ev, race, stage, stage ? Number(stage.replace(/\D/g, "")) || 99 : null, eventName, date, RIDERS[rows[0][0]][0]]);
  let i = 0;
  for (const [ri, pts] of rows) {
    await db.query(`insert into event_results (event_id, sort_order, rank, rank_text, rider_name, rider_slug, team, nation, result, uci_points)
                    values ($1, $2, $3, $10, $4, $5, $6, $7, $8, $9)`,
      [ev, ++i, i, RIDERS[ri][0], slugs[ri], RIDERS[ri][2], RIDERS[ri][1], i === 1 ? "4:12:33" : `+0:${String(i * 4).padStart(2, "0")}`, pts, String(i)]);
    await db.query("insert into results (rider_slug, race_slug, label, result_date, rank, uci_points) values ($1, $2, $3, $4, $5, $6)",
      [slugs[ri], race, label, date, i, pts]);
  }
};
await result(RACES[0][0], null, "Final Classification", day(-60), "result", [[0, 500], [3, 400], [1, 325], [7, 275], [5, 225]]);
await result(RACES[1][0], "Stage 1", "Stage Classification", day(-30), "stage-1", [[2, 60], [1, 25], [9, 10]]);
await result(RACES[1][0], "Stage 2", "Stage Classification", day(-29), "stage-2", [[4, 60], [2, 25], [10, 10]]);
await result(RACES[1][0], "Stage 3", "Stage Classification", day(-28), "stage-3", [[1, 60], [6, 25], [8, 10]]);
await result(RACES[1][0], "Final Classification", "General Classification", day(-28), "gc", [[2, 850], [1, 680], [4, 575], [6, 460], [9, 380]]);
await result(RACES[2][0], null, "Final Classification", day(-3), "result", [[12, 200], [13, 150], [0, 125], [16, 100], [11, 85]]);
await db.query("select refresh_season_stats($1)", [Y]);
await db.query("update sync_status set last_run = now(), ok = true");

// Nutzer und Liga
const users: Record<string, string> = {};
for (const n of ["alice", "bob", "carol"]) {
  users[n] = crypto.randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [users[n], `${n}@example.com`]);
}
const as = (uid: string) => db.query("select set_config('request.jwt.claim.sub', $1, false)", [uid]);
await as(users.alice);
const league = (await db.query("select create_league($1, 'Kette rechts', $2) id",
  [`UCI Fantasy ${Y}`, { gender: "men", roster_size: 6, draft_mode: "snake", season_start: `${Y}-01-01`, season_end: `${Y}-12-31` }])).rows[0].id;
const code = (await db.query("select invite_code from leagues where id = $1", [league])).rows[0].invite_code;
await as(users.bob);
await db.query("select join_league($1, 'Windschatten')", [code]);
await as(users.carol);
await db.query("select join_league($1, 'Bergziege')", [code]);
const mgr = Object.fromEntries((await db.query("select id, team_name from managers where league_id = $1", [league])).rows.map((r) => [r.team_name, r.id]));
const rosters: Record<string, number[]> = { "Kette rechts": [0, 3, 6, 9, 12, 15], Windschatten: [1, 4, 7, 10, 13], Bergziege: [2, 5, 8, 11, 14] };
let pos = 0;
for (const [team, idx] of Object.entries(rosters)) {
  await db.query("update managers set draft_position = $2 where id = $1", [mgr[team], ++pos]);
  for (const i of idx) {
    await db.query("insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on) values ($1, $2, $3, 0, 'draft', $4)",
      [league, mgr[team], slugs[i], `${Y}-01-01`]);
  }
}
await db.query("update leagues set status = 'active' where id = $1", [league]);
await db.query("update draft_state set status = 'done' where league_id = $1", [league]);
await as(users.alice);
for (const [name, s, e] of [["Frühjahr", -90, -40], ["Sommer", -39, -2]] as [string, number, number][]) {
  await db.query(`insert into matchdays (league_id, name, starts_on, ends_on, deadline, status, waivers_done, locked)
                  values ($1, $2, $3, $4, $3::date - 1, 'running', true, true)`, [league, name, day(s), day(e)]);
}
await db.query("select upsert_matchday($1, null, 'Herbst', $2, $3)", [league, day(10), day(40)]);
await db.query("update matchdays set status = 'running' where league_id = $1 and starts_on <= current_date", [league]);
await db.end();
console.log(users.alice);
