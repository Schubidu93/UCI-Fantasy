#!/usr/bin/env node
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSchema } from './build-schema.mjs';

const directory = dirname(fileURLToPath(import.meta.url));
const pgtapVersion = '1.3.4';
const pgtapHash = '383ecd73edfd1c7ed5f3b835134ee1fe74e201ee31599346c92ea029b65dcdce';

// psql liefert auch bei fehlgeschlagenen pgTAP-Assertions Exit-Code 0.
export function parseTap(output) {
  const lines = output.split(/\r?\n/);
  const plans = lines.filter(line => /^1\.\.\d+\s*$/.test(line));
  const assertions = lines.filter(line => /^(?:not )?ok\s+\d+\b/.test(line));
  if (lines.some(line => /^Bail out!/i.test(line))) throw new Error('pgTAP hat den Test abgebrochen.');
  if (plans.length !== 1) throw new Error('Genau ein pgTAP-Testplan wird erwartet.');
  const planned = Number(plans[0].slice(3).trim());
  if (planned < 1 || assertions.length !== planned) {
    throw new Error(`pgTAP: ${planned} Tests geplant, ${assertions.length} ausgeführt.`);
  }
  assertions.forEach((line, index) => {
    if (Number(line.match(/\d+/)[0]) !== index + 1) throw new Error('Ungültige pgTAP-Testnummerierung.');
    if (/^not ok\b/.test(line) || /#\s*(TODO|SKIP)\b/i.test(line)) throw new Error(line);
  });
  return planned;
}

async function pgtapSql() {
  const cache = join(tmpdir(), `uci-fantasy-pgtap-${pgtapVersion}.sql.in`);
  let bytes = existsSync(cache) ? readFileSync(cache) : null;
  const checksum = value => createHash('sha256').update(value).digest('hex');
  if (!bytes || checksum(bytes) !== pgtapHash) {
    const response = await fetch(`https://raw.githubusercontent.com/theory/pgtap/v${pgtapVersion}/sql/pgtap.sql.in`, {
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`pgTAP-Download fehlgeschlagen: HTTP ${response.status}`);
    bytes = Buffer.from(await response.arrayBuffer());
    if (checksum(bytes) !== pgtapHash) throw new Error('Die pgTAP-Prüfsumme stimmt nicht.');
    writeFileSync(cache, bytes);
  }
  // Dieselben Ersetzungen wie im upstream Makefile, für PostgreSQL >= 17.
  return 'set search_path = extensions, public;\n' + bytes.toString('utf8')
    .replaceAll('MODULE_PATHNAME', 'pgtap')
    .replaceAll('__OS__', process.platform === 'win32' ? 'MSWin32' : process.platform)
    .replaceAll('__VERSION__', '1.3');
}

async function main() {
  if (process.argv.length !== 2) throw new Error('Aufruf: node supabase/test-db.mjs (Verbindung über PGHOST/PGPORT/PGUSER/PGPASSWORD).');
  const host = process.env.PGHOST || '127.0.0.1';
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    throw new Error('Datenbanktests sind ausschließlich gegen localhost erlaubt.');
  }
  const port = process.env.PGPORT || '5432';
  if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) throw new Error('Ungültiger PGPORT.');
  const env = { ...process.env, PGCLIENTENCODING: 'UTF8', PGCONNECT_TIMEOUT: '10', PGAPPNAME: 'uci-fantasy-tests' };
  for (const key of ['PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE', 'PGDATABASE', 'PGOPTIONS']) delete env[key];
  const localPsql = process.platform === 'win32' && process.env.LOCALAPPDATA
    ? join(process.env.LOCALAPPDATA, 'Programs/PostgreSQL/17/bin/psql.exe') : '';
  const psql = process.env.PSQL || (localPsql && existsSync(localPsql) ? localPsql : 'psql');
  const connection = ['-X', '-w', '-q', '-A', '-t', '-h', host, '-p', port, '-U', process.env.PGUSER || 'postgres', '-v', 'ON_ERROR_STOP=1'];
  function run(database, { sql, file }, label) {
    const result = spawnSync(psql, [...connection, '-d', database, '-f', file || '-'], {
      input: sql, encoding: 'utf8', env, maxBuffer: 8 * 1024 * 1024, timeout: 120_000,
    });
    if (result.error) throw new Error(`${label}: ${result.error.message}`);
    if (result.status !== 0) throw new Error(`${label}:\n${result.stderr || result.stdout}`);
    return result.stdout;
  }
  const schemaFile = join(directory, 'schema.sql');
  if (readFileSync(schemaFile, 'utf8').replace(/\r\n/g, '\n') !== buildSchema()) {
    throw new Error('schema.sql ist veraltet. Zuerst node supabase/build-schema.mjs ausführen.');
  }
  const version = Number(run('postgres', { sql: 'show server_version_num;' }, 'PostgreSQL-Version').trim());
  if (version < 170000) throw new Error('Die Tests benötigen PostgreSQL ab Version 17.');
  const framework = await pgtapSql();
  const name = `uci_fantasy_test_${randomUUID().replaceAll('-', '').slice(0, 24)}`;
  let created = false;
  try {
    run('postgres', { sql: `create database "${name}" template template0;` }, 'Testdatenbank anlegen');
    created = true;
    console.log(`Testdatenbank: ${name}`);
    run(name, { file: join(directory, 'tests/support/bootstrap.sql') }, 'Lokale Supabase-Platzhalter');
    run(name, { file: schemaFile }, 'Schema erstmalig einspielen');
    console.log('Schema erstmalig eingespielt.');
    run(name, { sql: framework }, 'pgTAP laden');
    const tests = readdirSync(join(directory, 'tests/database')).filter(file => file.endsWith('.sql')).sort();
    if (!tests.length) throw new Error('Keine Datenbanktests gefunden.');
    let count = 0;
    const failures = [];
    for (const file of tests) {
      let output = '';
      try {
        output = run(name, { file: join(directory, 'tests/database', file) }, file);
        const assertions = parseTap(output);
        count += assertions;
        console.log(`${file}: ${assertions} Tests bestanden`);
      } catch (error) {
        failures.push(file);
        console.error(`${file}: FEHLER\n${output}\n${error.message}`);
      }
    }
    // Wiederholbarkeit mit Daten prüfen, zusätzlich zu den transaktionalen Tests.
    run(name, { file: join(directory, 'tests/support/upgrade_fixture.sql') }, 'Daten für erneutes Einspielen');
    const fingerprint = `select md5(string_agg(value, E'\\n' order by value)) from (
      select 'league:' || to_jsonb(t)::text value from leagues t
      union all select 'manager:' || to_jsonb(t)::text from managers t
      union all select 'roster:' || to_jsonb(t)::text from roster_entries t
      union all select 'matchday:' || to_jsonb(t)::text from matchdays t) rows;`;
    const before = run(name, { sql: fingerprint }, 'Daten vor erneutem Einspielen');
    run(name, { file: schemaFile }, 'Schema erneut einspielen');
    const after = run(name, { sql: fingerprint }, 'Daten nach erneutem Einspielen');
    if (before !== after) throw new Error('Erneutes Einspielen hat bestehende Testdaten verändert.');
    console.log('Schema erneut eingespielt; bestehende Testdaten unverändert.');
    if (failures.length) throw new Error(`Fehlgeschlagene Testsuiten: ${failures.join(', ')}`);
    console.log(`${count} pgTAP-Tests in ${tests.length} Dateien bestanden.`);
  } finally {
    if (created) {
      if (!/^uci_fantasy_test_[0-9a-f]{24}$/.test(name)) throw new Error('Ungültiger Name für die Testdatenbank.');
      run('postgres', { sql: `drop database "${name}" with (force);` }, 'Eigene Testdatenbank entfernen');
      console.log('Testdatenbank entfernt.');
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
