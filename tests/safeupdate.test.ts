// Supabase lädt pg_safeupdate für Aufrufe über die Schnittstelle (RPC): DELETE/UPDATE ohne WHERE scheitern dort
// („DELETE requires a WHERE clause“), im lokalen Test-PostgreSQL aber nicht. Darum hier statisch prüfen.
// Ausnahme: temporäre Hilfstabellen (Name beginnt mit _).
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const DIR = join(import.meta.dirname, "..", "supabase", "schema");

describe("Schema ohne DELETE/UPDATE ohne WHERE", () => {
  it("jede Anweisung hat eine Bedingung", () => {
    const bad: string[] = [];
    for (const f of readdirSync(DIR).filter((n) => n.endsWith(".sql"))) {
      // Kommentare entfernen, dann Anweisung bis zum Semikolon
      const sql = readFileSync(join(DIR, f), "utf8").replace(/--[^\n]*/g, "");
      for (const m of sql.matchAll(/\b(delete\s+from|update)\s+([a-z_][\w.]*)\b([^;]*);/gi)) {
        if (m[2].startsWith("_") || /\bon\s+conflict\b/i.test(sql.slice(Math.max(0, m.index! - 200), m.index))) continue;
        if (/^update$/i.test(m[1]) && !/^\s*(\w+\s+)?set\b/i.test(m[3])) continue;   // z. B. „for update“, „on update“
        if (!/\bwhere\b/i.test(m[3])) bad.push(`${f}: ${m[0].replace(/\s+/g, " ").slice(0, 80)}`);
      }
    }
    expect(bad).toEqual([]);
  });
});
