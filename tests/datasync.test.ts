// Datenabruf (datasync/, Python): Tests in tests/datasync/ – laufen mit `npm test` ohne Netz und ohne Datenbank.
import { execFileSync } from 'node:child_process';
import { expect, test } from 'vitest';

test('Datenabruf (Python-Tests in tests/datasync)', () => {
  const python = process.env.PYTHON || 'python3';
  let out = '';
  try {
    out = execFileSync(python, ['-m', 'unittest', 'discover', '-s', 'tests/datasync', '-t', 'tests/datasync', '-b'],
      { encoding: 'utf8', stdio: 'pipe' });
  } catch (e: any) {
    throw new Error(`${e.stdout || ''}${e.stderr || ''}`);
  }
  expect(out).toBe('');
});
