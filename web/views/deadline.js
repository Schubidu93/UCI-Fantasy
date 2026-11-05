// Fristen transparent: wann ist der nächste Stichtag, was passiert dort, was muss man bis dahin tun
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { fmtDate } from '../lib.js';

export const fmtDeadline = (d) => new Date(d).toLocaleString('de-DE',
  { weekday: 'short', day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' }) + ' Uhr';

// „in 3 Tagen 4 Std.“ / „in 45 Min.“
export function untilText(d) {
  const ms = new Date(d) - Date.now();
  if (ms <= 0) return 'abgelaufen';
  const min = Math.floor(ms / 60000), h = Math.floor(min / 60), days = Math.floor(h / 24);
  if (days >= 1) return `in ${days} ${days === 1 ? 'Tag' : 'Tagen'}${h % 24 ? ` ${h % 24} Std.` : ''}`;
  if (h >= 1) return `in ${h} Std. ${min % 60} Min.`;
  return `in ${min} Min.`;
}

// Zeitraum, in dem Anträge/Aufstellung für einen Spieltag gelten: vom vorigen Stichtag bis zu seinem eigenen
export const windowStart = (c, md) => {
  const i = c.matchdays.findIndex((m) => m.id === md.id);
  return i > 0 ? c.matchdays[i - 1].deadline : null;
};

export function NextDeadline({ c, compact }) {
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((x) => x + 1), 60000); return () => clearInterval(t); }, []);
  if (c.league.status !== 'active') return null;
  const md = c.nextMatchday;
  const today = new Date().toISOString().slice(0, 10);
  const running = c.matchdays.find((m) => m.starts_on <= today && m.ends_on >= today);
  if (!md) return html`<section class="card deadline"><p class="muted small">Kein kommender Spieltag angelegt – Waiver und Aufstellung sind erst wieder möglich, wenn der Admin den nächsten Spieltag festlegt.</p></section>`;
  const lineup = c.league.scoring_mode === 'lineup';
  return html`<section class="card deadline">
    <div class="deadline-head">
      <span class="deadline-icon" aria-hidden="true">⏰</span>
      <div>
        <div class="muted small">Nächster Stichtag · vor ${md.name} (${fmtDate(md.starts_on)} – ${fmtDate(md.ends_on)})</div>
        <div class="deadline-time">${fmtDeadline(md.deadline)} <span class="tag warn">${untilText(md.deadline)}</span></div>
      </div>
    </div>
    ${!compact && html`<ul class="small deadline-list">
      <li><strong>Bis dahin:</strong> Waiver-Anträge stellen oder ändern${lineup ? `, Aufstellung für ${md.name} festlegen` : ''}, Tauschangebote annehmen.</li>
      <li><strong>Am Stichtag:</strong> Waiver und Tausche werden ausgeführt – neue Fahrer zählen ab ${md.name}${lineup ? ', die Aufstellung ist dann fest' : ''}.</li>
      ${running && running.id !== md.id && html`<li><strong>Läuft gerade:</strong> ${running.name} bis ${fmtDate(running.ends_on)} – Kader${lineup ? ' und Aufstellung' : ''} dafür sind fest.</li>`}
      <li><strong>Danach</strong> gestellte Anträge gelten für den folgenden Spieltag.</li>
    </ul>`}
  </section>`;
}
