#!/usr/bin/env node
// Gemeinsame Dateien von Runner Fantasy und UCI Fantasy: Prüfsummen in shared-files.json (in beiden Apps gleich).
//   node scripts/shared.mjs          → prüfen (auch Teil von npm test)
//   node scripts/shared.mjs update   → nach einer bewusst in BEIDE Apps übernommenen Änderung neu berechnen
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = join(import.meta.dirname, '..');
// Gemeinsam ist alles in diesen Dateien und Ordnern …
const GLOBS = ['web/app.js', 'web/lib.js', 'web/style.css', 'web/vendor', 'web/views', 'datasync/db.py', 'datasync/send_push.py',
  'datasync/send_feedback.py', 'supabase/schema', 'tests/sql', 'tests/datasync/helpers.py', 'tests/datasync/test_common.py',
  'tests/datasync.test.ts', 'tests/workflows.test.ts', 'tests/ui/mock-api.ts', 'tests/ui/smoke.test.ts', 'tests/sql.test.ts', 'tests/shared.test.ts',
  'tests/upgrade.test.ts', 'tests/supabase-stub.sql', 'vitest.config.ts', 'tsconfig.json', '.github/workflows/ci.yml', '.github/workflows/health.yml', '.claude',
  'scripts/shared.mjs'];
// … außer dem, worin sich die Sportarten unterscheiden (Datenbank: Tabellen, Sportart, Liga-Einstellungen, Aufstellung,
// Wertung, Rechte, Einspielen; Tests: Aufstellung und Beispieldaten). Neue Dateien sind damit erst einmal gemeinsam.
const SPORT_FILES = /^supabase\/schema\/(01|02|04|09|10|11|15|18|99)_|^tests\/sql\/(06_deadlines|fixtures)\.sql$/;
const walk = (p) => (statSync(p).isDirectory() ? readdirSync(p).flatMap((f) => walk(join(p, f))) : [p]);
export const sharedFiles = () => GLOBS.flatMap((g) => walk(join(ROOT, g))).map((f) => relative(ROOT, f))
  .filter((f) => !SPORT_FILES.test(f)).sort();
export const hashes = () => Object.fromEntries(sharedFiles().map((f) => [f, createHash('sha256').update(readFileSync(join(ROOT, f))).digest('hex').slice(0, 16)]));

const FILE = join(ROOT, 'shared-files.json');
if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv[2] === 'update') {
    writeFileSync(FILE, JSON.stringify(hashes(), null, 2) + '\n');
    console.log('shared-files.json neu berechnet – dieselbe Datei auch in der anderen App ablegen.');
  } else {
    const want = JSON.parse(readFileSync(FILE, 'utf8')), have = hashes();
    const diff = [...new Set([...Object.keys(want), ...Object.keys(have)])].filter((f) => want[f] !== have[f]);
    if (diff.length) { console.error('Gemeinsame Dateien geändert (in beide Apps übernehmen, dann „update“):\n  ' + diff.join('\n  ')); process.exit(1); }
    console.log(`${Object.keys(have).length} gemeinsame Dateien unverändert.`);
  }
}
