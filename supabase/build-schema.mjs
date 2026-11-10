#!/usr/bin/env node
// Keine Abhängigkeiten: node supabase/build-schema.mjs [--check]
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const schemaDirectory = dirname(fileURLToPath(import.meta.url));
const header = `-- AUTOMATISCH ERZEUGT. Bitte die Module unter supabase/sql/ bearbeiten.
-- Reihenfolge: supabase/schema.modules.json
-- Erzeugen: node supabase/build-schema.mjs
-- Prüfen:   node supabase/build-schema.mjs --check

`;

function readText(file) {
  return readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
}

function sqlFiles(directory, prefix = 'sql') {
  return readdirSync(join(directory, prefix), { withFileTypes: true }).flatMap(entry => {
    const name = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) return sqlFiles(directory, name);
    return entry.isFile() && entry.name.endsWith('.sql') ? [name] : [];
  });
}

export function buildSchema(directory = schemaDirectory) {
  const modules = JSON.parse(readText(join(directory, 'schema.modules.json')));
  if (!Array.isArray(modules) || modules.length === 0) {
    throw new Error('schema.modules.json muss eine nicht leere Liste von SQL-Modulen enthalten.');
  }
  const listed = new Set();
  for (const name of modules) {
    if (typeof name !== 'string' || !/^sql\/(?:[a-z0-9_]+\/)*[a-z0-9_]+\.sql$/.test(name)) {
      throw new Error(`Ungültiger Modulpfad: ${name}`);
    }
    if (listed.has(name)) throw new Error(`Modul doppelt eingetragen: ${name}`);
    listed.add(name);
  }

  const files = new Set(sqlFiles(directory));
  const missing = modules.filter(name => !files.has(name));
  const unlisted = [...files].filter(name => !listed.has(name)).sort();
  if (missing.length || unlisted.length) {
    throw new Error([
      missing.length ? `Fehlende Module: ${missing.join(', ')}` : '',
      unlisted.length ? `Nicht eingetragene Module: ${unlisted.join(', ')}` : '',
    ].filter(Boolean).join('\n'));
  }

  return header + modules.map(name => {
    const content = readText(join(directory, name));
    if (!content.trim()) throw new Error(`Leeres SQL-Modul: ${name}`);
    return `-- Modul: ${name}\n${content}${content.endsWith('\n') ? '' : '\n'}`;
  }).join('');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length > 1 || (args.length === 1 && args[0] !== '--check')) {
      throw new Error('Aufruf: node supabase/build-schema.mjs [--check]');
    }
    const expected = buildSchema();
    const target = join(schemaDirectory, 'schema.sql');
    if (args[0] === '--check') {
      let actual;
      try {
        actual = readText(target);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      if (actual !== expected) {
        throw new Error('supabase/schema.sql ist nicht aktuell. Bitte node supabase/build-schema.mjs ausführen und die Datei mit einchecken.');
      }
      console.log('supabase/schema.sql stimmt mit den SQL-Modulen überein.');
    } else {
      writeFileSync(target, expected, 'utf8');
      console.log('supabase/schema.sql aus den SQL-Modulen erzeugt.');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
