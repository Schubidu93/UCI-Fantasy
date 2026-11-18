// Gemeinsame Dateien (Athletics Fantasy und UCI Fantasy wortgleich): Prüfsummen in shared-files.json.
// Schlägt fehl, wenn eine gemeinsame Datei nur in einer App geändert wurde – dann die Änderung in die andere App
// übernehmen und in beiden `node scripts/shared.mjs update` ausführen (shared-files.json ist in beiden Apps gleich).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, it } from "vitest";
// @ts-expect-error – Skript ohne Typen
import { hashes } from "../scripts/shared.mjs";

it("gemeinsame Dateien sind unverändert (gleich in beiden Apps)", () => {
  const want = JSON.parse(readFileSync(join(import.meta.dirname, "..", "shared-files.json"), "utf8"));
  expect(hashes()).toEqual(want);
});
