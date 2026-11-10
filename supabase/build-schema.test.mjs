import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { buildSchema } from './build-schema.mjs';

function fixture(t, modules, contents) {
  const parent = resolve(tmpdir());
  const directory = mkdtempSync(join(parent, 'uci-schema-test-'));
  t.after(() => {
    const child = relative(parent, resolve(directory));
    assert.ok(child.startsWith('uci-schema-test-') && !child.includes(sep));
    rmSync(directory, { recursive: true, force: true });
  });
  mkdirSync(join(directory, 'sql'));
  writeFileSync(join(directory, 'schema.modules.json'), JSON.stringify(modules));
  for (const [name, content] of Object.entries(contents)) {
    mkdirSync(dirname(join(directory, name)), { recursive: true });
    writeFileSync(join(directory, name), content);
  }
  return directory;
}

test('Manifest bestimmt die Reihenfolge; Inhalte einschließlich Funktionskörper bleiben erhalten', t => {
  const first = "do $$\r\nbegin\r\n  raise notice '-- kein Kommentar';\r\nend $$;\r\n";
  const second = 'select 1; -- ohne abschließenden Zeilenumbruch';
  const directory = fixture(t, ['sql/z.sql', 'sql/a.sql'], {
    'sql/z.sql': first,
    'sql/a.sql': second,
  });
  const result = buildSchema(directory);
  assert.ok(result.endsWith(
    `-- Modul: sql/z.sql\n${first.replace(/\r\n/g, '\n')}-- Modul: sql/a.sql\n${second}\n`,
  ));
  assert.equal(result, buildSchema(directory));
});

test('Doppelte Module werden abgewiesen', t => {
  const directory = fixture(t, ['sql/a.sql', 'sql/a.sql'], { 'sql/a.sql': 'select 1;' });
  assert.throws(() => buildSchema(directory), /doppelt.*sql\/a.sql/);
});

test('Fehlende und nicht eingetragene Module werden gemeinsam gemeldet', t => {
  const directory = fixture(t, ['sql/missing.sql'], { 'sql/new.sql': 'select 1;' });
  assert.throws(() => buildSchema(directory), error => {
    assert.match(error.message, /Fehlende Module: sql\/missing.sql/);
    assert.match(error.message, /Nicht eingetragene Module: sql\/new.sql/);
    return true;
  });
});

test('Leere Module werden abgewiesen', t => {
  const directory = fixture(t, ['sql/empty.sql'], { 'sql/empty.sql': '\n  ' });
  assert.throws(() => buildSchema(directory), /Leeres SQL-Modul/);
});

test('Ungültige Manifeste und Pfade werden abgewiesen', t => {
  for (const modules of [[], {}, ['../schema.sql'], ['sql/../schema.sql'], [null]]) {
    const directory = fixture(t, modules, {});
    assert.throws(() => buildSchema(directory), /Liste|Modulpfad/);
  }
});

test('CLI erkennt eine veraltete Ausgabedatei, ohne sie zu überschreiben', t => {
  const directory = fixture(t, ['sql/a.sql'], { 'sql/a.sql': 'select 1;\n' });
  const script = join(directory, 'build-schema.mjs');
  writeFileSync(script, readFileSync(new URL('./build-schema.mjs', import.meta.url)));
  const target = join(directory, 'schema.sql');
  writeFileSync(target, '-- veraltete Ausgabe\n');
  const stale = spawnSync(process.execPath, [script, '--check'], { encoding: 'utf8' });
  assert.equal(stale.status, 1);
  assert.match(stale.stderr, /nicht aktuell/);
  assert.equal(readFileSync(target, 'utf8'), '-- veraltete Ausgabe\n');

  const built = spawnSync(process.execPath, [script], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.stderr);
  assert.equal(readFileSync(target, 'utf8'), buildSchema(directory));
  const checked = spawnSync(process.execPath, [script, '--check'], { encoding: 'utf8' });
  assert.equal(checked.status, 0, checked.stderr);
});
