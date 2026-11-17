// SQL-Tests der Spiellogik (tests/sql/NN_*.sql, pgTAP-Schreibweise): jede Datei läuft in einer eigenen
// Transaktion auf einer frischen Datenbank mit Beispieldaten (tests/sql/fixtures.sql) und wird zurückgerollt.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { freshDb, type Db } from "./db";

const DIR = join(import.meta.dirname, "sql");
const read = (f: string) => readFileSync(join(DIR, f), "utf8");
// \ir-Anweisungen (psql) durch den Dateiinhalt ersetzen
const expand = (sql: string) => sql.replace(/^\\ir \.\.\/support\/(\S+)\s*$/gm, (_, f) => read(f));

let db: Db;
beforeAll(async () => { db = await freshDb(); await db.query(read("_tap.sql")); });
afterAll(async () => { await db.end(); });

describe("SQL-Tests", () => {
  for (const f of readdirSync(DIR).filter((x) => /^\d\d_.*\.sql$/.test(x)).sort()) {
    it(f.replace(/\.sql$/, ""), async () => {
      await db.query("truncate _tap_results");
      try {
        const res = await db.query(expand(read(f)));
        const rows = (Array.isArray(res) ? res : [res]).flatMap((r) => r.rows ?? []);
        expect(rows.length).toBeGreaterThan(0);
      } catch (e) {
        await db.query("rollback").catch(() => {});
        throw e;
      }
    });
  }
});
