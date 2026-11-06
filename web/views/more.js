// Bereich "Mehr": Regeln, Draft, Admin, Benachrichtigungen, Liga wechseln, Abmelden
import { html } from '../vendor/preact-htm.js';
import { sb } from '../lib.js';
import { PushToggle } from './push.js';

export function More({ c }) {
  const L = c.league.id;
  const before = ['setup', 'drafting'].includes(c.league.status);
  const link = (k, title, text) => html`<a class="card link" href=${`#/league/${L}/${k}`}><strong>${title}</strong><span class="muted small">${text}</span></a>`;
  return html`<div class="stack">
    <div class="cards">
      ${link('rules', '📖 Regeln', 'Spielregeln und Einstellungen dieser Liga')}
      ${!before && link('draft', '📋 Draft', 'Ergebnis des Drafts')}
      ${c.isAdmin && link('admin', '⚙️ Admin', 'Einstellungen, Mitglieder, Spieltage, Korrekturen')}
      ${link('feedback', '💬 Feedback', 'Fehler, Ideen, Wünsche – gern mit Bildschirmfoto')}
      <a class="card link" href="#/"><strong>🏠 Meine Ligen</strong><span class="muted small">Liga wechseln oder neue anlegen</span></a>
    </div>
    <${PushToggle} />
    <div class="row"><button class="ghost" onClick=${() => sb.auth.signOut()}>Abmelden</button></div>
  </div>`;
}
