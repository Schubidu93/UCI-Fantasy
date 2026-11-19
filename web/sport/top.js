// Top-Ergebnisse: einzelne Ergebnisse mit den meisten Punkten in einem Zeitraum (Standard: letzte 30 Tage);
// ab dem ersten Spieltag auch nur die Ergebnisse, die einem Team der Liga Punkte gebracht haben
import { html, useState } from '../vendor/preact-htm.js';
import { fmtDate, fmtPts, Loading, openRider, rpc, useLoad } from '../lib.js';
import { labelText } from './index.js';

const iso = (d) => d.toISOString().slice(0, 10);
const daysAgo = (n) => { const d = new Date(); d.setDate(d.getDate() - n); return iso(d); };
const PERIODS = [['7', 'Letzte 7 Tage'], ['30', 'Letzte 30 Tage'], ['year', 'Dieses Jahr'], ['custom', 'Eigener Zeitraum']];
function range(period, from, to) {
  if (period === 'year') return [`${new Date().getFullYear()}-01-01`, iso(new Date())];
  if (period === 'custom') return [from || '2025-01-01', to || iso(new Date())];
  return [daysAgo(Number(period) - 1), iso(new Date())];
}

// Auswahl bleibt beim Zurückkehren aus einem Fahrerprofil erhalten
const saved = { period: '30', from: daysAgo(29), to: iso(new Date()), team: '' };
const keep = (key, setter) => (v) => { saved[key] = v; setter(v); };

export function TopResults({ c }) {
  const [period, setPeriodRaw] = useState(saved.period);
  const [from, setFromRaw] = useState(saved.from);
  const [to, setToRaw] = useState(saved.to);
  const [teamRaw, setTeamRaw] = useState(saved.team);
  const setPeriod = keep('period', setPeriodRaw), setFrom = keep('from', setFromRaw), setTo = keep('to', setToRaw);
  const setTeam = keep('team', setTeamRaw);
  const started = (c.matchdays || []).some((m) => m.starts_on <= iso(new Date()));
  const team = started && c.managers.some((m) => m.id === teamRaw) ? teamRaw : '';
  const [a, b] = range(period, from, to);
  const list = useLoad(() => rpc('top_results', { p_gender: c.league.gender, p_from: a, p_to: b, p_limit: 100,
    p_league: c.league.id, p_manager: team || null }), [c.league.id, c.league.gender, a, b, team]);
  const rows = list.data || [];

  return html`<section class="card">
    <h2>Top-Ergebnisse</h2>
    <p class="muted small">Die einzelnen Ergebnisse mit den meisten Punkten.${team ? ' Nur Ergebnisse, die diesem Team in der Liga Punkte gebracht haben.' : ''}</p>
    <div class="filters">
      <select value=${period} onChange=${(e) => setPeriod(e.target.value)} aria-label="Zeitraum">
        ${PERIODS.map(([k, l]) => html`<option value=${k}>${l}</option>`)}</select>
      ${started && html`<select value=${team} onChange=${(e) => setTeam(e.target.value)} aria-label="Team">
        <option value="">Alle Teams</option>${c.managers.map((m) => html`<option value=${m.id}>${m.team_name}</option>`)}</select>`}
      ${period === 'custom' && html`<label class="small">von <input type="date" value=${from} max=${to} onChange=${(e) => setFrom(e.target.value)} /></label>
        <label class="small">bis <input type="date" value=${to} min=${from} onChange=${(e) => setTo(e.target.value)} /></label>`}
    </div>
    ${!list.data ? html`<${Loading} error=${list.error} />` : rows.length === 0 ? html`<p class="muted">Keine Ergebnisse mit Punkten in diesem Zeitraum.</p>` : html`
      <ul class="list compact">${rows.map((r, i) => {
        const owner = c.managerMap[c.owner[r.athlete_id]];
        return html`<li key=${`${r.athlete_id}|${r.competition_id}|${r.label}`} class=${owner && owner.id === c.me?.id ? 'me' : ''}>
          <span><span class="res-place">${i + 1}.</span>${' '}
            <button type="button" class="linkish" onClick=${() => openRider(r.athlete_id)}>${c.riderMap[r.athlete_id]?.name || r.athlete_id}</button>
            <small class="muted"><br />${r.competition || r.competition_id}${r.category ? ` (${r.category})` : ''} · ${labelText(r.label)}${r.rank ? ` · Platz ${r.rank}` : ''}
              <br />${fmtDate(r.result_date)} · ${owner ? owner.team_name : 'frei'}</small></span>
          <span><strong>${fmtPts(r.points)}</strong></span></li>`;
      })}</ul>`}
  </section>`;
}
