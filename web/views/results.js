import { html, useState } from '../vendor/preact-htm.js';
import { rpc, useLoad, Loading, fmtDate, fmtDateTime, fmtPts } from '../lib.js';
import { fmtUntil } from '../lib.js';
import { NextDeadline, windowStart } from './deadline.js';

const MD_STATUS = (md) => (md.frozen ? 'eingefroren' : md.status === 'closed' ? 'abgeschlossen (Korrekturen 7 Tage)' : md.status === 'running' ? 'läuft' : 'geplant');

const LABELS = [
  [/^Final Classification · General Classification$/, 'Gesamtwertung'],
  [/^Final Classification$/, 'Ergebnis'],
  [/^Final Classification · /, ''],
  [/^Stage (\d+) · Stage Classification$/, 'Etappe $1'],
  [/^Stage (\d+) · Stage General Classification$/, 'Etappe $1 · Gesamtführung'],
  [/^Prologue · Stage Classification$/, 'Prolog'],
  [/^Prologue · Stage General Classification$/, 'Prolog · Gesamtführung'],
  [/General Classification/g, 'Gesamtwertung'], [/Mountains? Classification/g, 'Bergwertung'],
  [/Points Classification/g, 'Punktewertung'], [/Young Riders? Classification/g, 'Nachwuchswertung'],
  [/^Stage (\d+)/, 'Etappe $1'], [/^Prologue/, 'Prolog'],
];
export const labelText = (l) => {
  if (!l || l === 'result') return 'Ergebnis';
  return LABELS.reduce((t, [re, rep]) => t.replace(re, rep), l);
};

export function Results({ c }) {
  const started = c.matchdays.filter((m) => m.status !== 'planned' || m.starts_on <= new Date().toISOString().slice(0, 10));
  const [mdId, setMdId] = useState(started[started.length - 1]?.id || '');
  const details = useLoad(() => (mdId ? rpc('league_point_details', { p_league: c.league.id, p_matchday: mdId }) : Promise.resolve([])), [mdId]);
  const pts = useLoad(() => rpc('league_points', { p_league: c.league.id }), [c.league.id]);
  const [open, setOpen] = useState(null);

  if (!started.length) return html`<div class="stack">
    <${NextDeadline} c=${c} />
    <p class="card muted">${c.matchdays.length
      ? `Noch kein Spieltag begonnen – der erste startet am ${fmtDate(c.matchdays[0].starts_on)}.`
      : html`Noch keine Spieltage angelegt.`}${c.isAdmin ? html` <a href=${`#/league/${c.league.id}/admin`}>Jetzt anlegen →</a>` : ' Der Admin legt sie fest.'}</p>
    <${Schedule} c=${c} />
  </div>`;
  const md = c.matchdays.find((m) => m.id === mdId);
  const rows = (pts.data || []).filter((p) => p.matchday_id === mdId);
  const teams = c.managers.map((m) => ({
    m, total: rows.filter((r) => r.manager_id === m.id).reduce((s, r) => s + Number(r.points), 0),
  })).sort((a, b) => b.total - a.total);

  return html`<div class="stack">
    <${NextDeadline} c=${c} compact />
    <div class="row between">
      <label class="inline">Spieltag
        <select value=${mdId} onChange=${(e) => { setMdId(e.target.value); setOpen(null); }}>
          ${started.map((m) => html`<option value=${m.id}>${m.name}</option>`)}
        </select></label>
      ${md && html`<span class="muted small">${fmtDate(md.starts_on)} – ${fmtDate(md.ends_on)} · ${MD_STATUS(md)}</span>`}
    </div>
    ${!pts.data || !details.data ? html`<${Loading} error=${pts.error || details.error} />` : html`
      <section class="card"><table class="tbl">
        <thead><tr><th>#</th><th>Team</th><th class="num">Punkte</th></tr></thead>
        <tbody>${teams.map(({ m, total }, i) => html`
          <tr key=${m.id} class=${`click ${m.id === c.me?.id ? 'me' : ''}`} onClick=${() => setOpen(open === m.id ? null : m.id)}>
            <td>${i + 1}</td><td>${open === m.id ? '▾' : '▸'} ${m.team_name}</td><td class="num"><strong>${fmtPts(total)}</strong></td></tr>
          ${open === m.id && html`<tr><td></td><td colspan="2"><${TeamDetail} c=${c} rows=${rows.filter((r) => r.manager_id === m.id)}
              details=${details.data.filter((d) => d.manager_id === m.id)} /></td></tr>`}`)}
        </tbody></table></section>`}
    <${Schedule} c=${c} current=${mdId} />
  </div>`;
}

// Spielplan: alle Spieltage mit Zeitraum, Stichtag und Status – auch künftige
function Schedule({ c, current }) {
  const today = new Date().toISOString().slice(0, 10);
  if (!c.matchdays.length) return html`<section class="card"><h3>Spielplan</h3>
    <p class="muted small">${c.isAdmin ? 'Lege die Spieltage unter Mehr → Admin an (z. B. Klassiker, Giro, Tour, Vuelta).' : 'Der Admin hat noch keine Spieltage festgelegt.'}</p></section>`;
  const next = c.matchdays.find((m) => m.ends_on >= today);
  const tag = (m) => m.frozen ? html`<span class="tag">eingefroren</span>`
    : m.status === 'closed' ? html`<span class="tag">abgeschlossen</span>`
    : m.starts_on <= today && m.ends_on >= today ? html`<span class="tag ok">läuft</span>`
    : m === next ? html`<span class="tag warn">als Nächstes</span>` : html`<span class="tag">geplant</span>`;
  return html`<section class="card"><h3>Spielplan</h3>
    <ul class="list md-plan">${c.matchdays.map((m, i) => html`<li key=${m.id} class=${m.id === current ? 'me' : ''}>
      <span class="md-no">${i + 1}</span>
      <span class="md-what"><strong>${m.name}</strong>
        <small>${fmtDate(m.starts_on)} – ${fmtDate(m.ends_on)}</small>
        ${c.league.transfer_mode === 'waiver_free'
          ? html`<small>Waiver bis ${fmtUntil(m.waiver_deadline || m.deadline)} · frei bis ${fmtUntil(m.deadline)}</small>`
          : html`<small>Waiver${c.league.scoring_mode === 'lineup' ? ' & Aufstellung' : ''} bis ${fmtUntil(m.deadline)}</small>`}</span>
      ${tag(m)}</li>`)}</ul>
  </section>`;
}

function TeamDetail({ c, rows, details }) {
  if (!rows.length) return html`<p class="muted small">Keine Punkte in diesem Spieltag.</p>`;
  return html`<div class="detail">${rows.sort((a, b) => b.points - a.points).map((r) => html`<div key=${r.rider_slug} class="detail-rider">
    <div class="row between"><strong>${c.riderMap[r.rider_slug]?.name || r.rider_slug}</strong>
      <span>${fmtPts(r.points)}${r.overridden ? html` <span class="tag warn" title="vom Admin korrigiert">korrigiert</span>` : ''}</span></div>
    <ul class="list compact">${details.filter((d) => d.rider_slug === r.rider_slug).map((d) => html`<li>
      <span>${d.race_name || d.race_slug} – ${labelText(d.label)}</span>
      <span class="muted">${fmtDate(d.result_date)} · ${fmtPts(d.points)}</span></li>`)}</ul>
  </div>`)}</div>`;
}
