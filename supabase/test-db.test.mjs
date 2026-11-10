import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseTap } from './test-db.mjs';

test('Vollständiger erfolgreicher TAP-Lauf wird erkannt', () => {
  assert.equal(parseTap('1..2\r\nok 1 - Budget\r\nok 2 - Frist\r\n'), 2);
});
test('Fehlgeschlagene Assertion wird trotz erfolgreichem psql-Prozess abgewiesen', () => {
  assert.throws(() => parseTap('1..1\nnot ok 1 - fremde Daten\n# diagnostic'), /fremde Daten/);
});
test('Fehlender, doppelter oder unvollständiger Testplan wird abgewiesen', () => {
  for (const output of ['ok 1', '1..1\n1..1\nok 1', '1..2\nok 1', '1..0']) {
    assert.throws(() => parseTap(output));
  }
});
test('Abbruch und ungültige Nummerierung werden abgewiesen', () => {
  assert.throws(() => parseTap('1..1\nBail out!\nok 1'), /abgebrochen/);
  assert.throws(() => parseTap('1..2\nok 1\nok 1'), /nummerierung/i);
});
test('Übersprungene Tests zählen nicht als bestandene Prüfung', () => {
  assert.throws(() => parseTap('1..1\nok 1 # SKIP'), /SKIP/);
  assert.throws(() => parseTap('1..1\nok 1 # TODO'), /TODO/);
});
test('Ferne Datenbankverbindungen werden vor jedem Datenbankzugriff abgewiesen', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./test-db.mjs', import.meta.url))], {
    encoding: 'utf8', env: { ...process.env, PGHOST: 'production.example.invalid' },
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /ausschließlich gegen localhost/);
  assert.equal(result.stdout, '');
});
