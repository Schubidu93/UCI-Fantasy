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

// Aktuelle Transferphase für den nächsten Spieltag
export function transferPhase(c) {
  const md = c.nextMatchday;
  if (!md) return { md: null, phase: null };
  const two = c.league.transfer_mode === 'waiver_free';
  const wd = md.waiver_deadline || md.deadline;
  const free = two && (md.waivers_done || new Date(wd) <= new Date());
  return { md, two, wd, lock: md.deadline, phase: free ? 'free' : 'waiver' };
}

export function NextDeadline({ c, compact }) {
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((x) => x + 1), 60000); return () => clearInterval(t); }, []);
  if (c.league.status !== 'active') return null;
  const { md, two, wd, lock, phase } = transferPhase(c);
  const today = new Date().toISOString().slice(0, 10);
  const running = c.matchdays.find((m) => m.starts_on <= today && m.ends_on >= today);
  if (!md) return html`<section class="card deadline"><p class="muted small">Kein kommender Spieltag angelegt – Transfers und Aufstellung sind erst wieder möglich, wenn es einen nächsten Spieltag gibt.
    ${c.isAdmin ? html` <a href=${`#/league/${c.league.id}/admin`}>Jetzt anlegen →</a>` : ' Der Admin legt sie fest.'}</p></section>`;
  const lineup = c.league.scoring_mode === 'lineup';
  const next = two && phase === 'waiver' ? wd : lock;
  const steps = two ? [
    ['Waiver-Runde', `bis ${fmtDeadline(wd)}`, 'Anträge stellen – ausgewertet in Waiver-Reihenfolge', phase === 'waiver'],
    ['Freie Phase', `${fmtDeadline(wd)} – ${fmtDeadline(lock)}`, 'freie Fahrer sofort holen und abgeben, wer zuerst kommt', phase === 'free'],
    ['Stichtag', fmtDeadline(lock), `Kader${lineup ? ' und Aufstellung' : ''} für ${md.name} sind fest`, false],
  ] : [
    ['Waiver', `bis ${fmtDeadline(lock)}`, `Anträge stellen${lineup ? ', Aufstellung festlegen' : ''}`, true],
    ['Stichtag', fmtDeadline(lock), `Waiver werden ausgewertet, Kader${lineup ? ' und Aufstellung' : ''} für ${md.name} sind fest`, false],
  ];
  return html`<section class="card deadline">
    <div class="deadline-head">
      <span class="deadline-icon" aria-hidden="true">⏰</span>
      <div>
        <div class="muted small">${two && phase === 'free' ? 'Freie Phase läuft' : two ? 'Waiver-Runde läuft' : 'Nächster Stichtag'} · für ${md.name} (${fmtDate(md.starts_on)} – ${fmtDate(md.ends_on)})</div>
        <div class="deadline-time">${two && phase === 'waiver' ? 'Waiver bis ' : two ? 'Frei bis ' : ''}${fmtDeadline(next)} <span class="tag warn">${untilText(next)}</span></div>
      </div>
    </div>
    ${!compact && html`<ol class="small phase-list">${steps.map(([t, when, what, active]) => html`<li class=${active ? 'active' : ''}>
        <strong>${t}</strong> <span class="muted">${when}</span><br />${what}</li>`)}</ol>
      <p class="muted small">Alle Wechsel gelten ab ${md.name}${running && running.id !== md.id ? ` – im laufenden Spieltag ${running.name} bleibt dein Kader${lineup ? ' samt Aufstellung' : ''} unverändert` : ''}. Danach gestellte Anträge gelten für den folgenden Spieltag.</p>`}
  </section>`;
}
