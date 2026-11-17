// Admin-Bereich einer Liga (nur Liga-Admin): Reiter und Seiten. Zusätzliche Reiter liefert die Sportart (sport/admin.js).
import { html } from '../../vendor/preact-htm.js';
import { Settings } from './settings.js';
import { Members } from './members.js';
import { OfflineImport } from './offline.js';
import { Matchdays } from './matchdays.js';
import { Fixes } from './fixes.js';
import { Log } from './log.js';
import { ADMIN_SECTIONS, ADMIN_VIEWS } from '../../sport/admin.js';

const SECTIONS = [['settings', 'Einstellungen'], ['members', 'Mitglieder'], ['import', 'Offline-Draft'],
  ['matchdays', 'Spieltage'], ...ADMIN_SECTIONS, ['fix', 'Korrekturen'], ['log', 'Protokoll']];

export function Admin({ c, sub }) {
  if (!c.isAdmin) return html`<p class="card muted">Nur für den Liga-Admin.</p>`;
  const s = sub || 'settings';
  const View = { settings: Settings, members: Members, import: OfflineImport, matchdays: Matchdays, fix: Fixes, log: Log, ...ADMIN_VIEWS }[s];
  return html`<div class="stack">
    <nav class="seg wrap-seg">${SECTIONS.filter(([k]) => k !== 'import' || c.league.draft_mode === 'offline').map(([k, l]) =>
      html`<a href=${`#/league/${c.league.id}/admin/${k}`} class=${k === s ? 'active' : ''}>${l}</a>`)}</nav>
    <${View} c=${c} />
  </div>`;
}
