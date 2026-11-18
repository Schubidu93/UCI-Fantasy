// Jeder Ablauf, den die Datenbank startet (dispatch_workflow('…yml')), muss es unter .github/workflows geben –
// sonst fällt z. B. der nächtliche Abruf still aus.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, it } from "vitest";

const ROOT = join(import.meta.dirname, "..");

it("von der Datenbank gestartete Abläufe existieren", () => {
  const dir = join(ROOT, "supabase/schema");
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql"));
  const used = new Set(files.flatMap((f) => [...readFileSync(join(dir, f), "utf8").matchAll(/dispatch_workflow\('([^']+\.yml)'/g)].map((m) => m[1])));
  expect(used.size).toBeGreaterThan(0);
  const missing = [...used].filter((w) => !existsSync(join(ROOT, ".github/workflows", w)));
  expect(missing).toEqual([]);
});
