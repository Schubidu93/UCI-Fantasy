// Team → Punkte: wer hat dem Team in der Saison bzw. an einem Spieltag wie viele Punkte gebracht
import { html, useState } from '../vendor/preact-htm.js';
import { rpc, useLoad, Loading, fmtPts, fmtDate, openRider } from '../lib.js';
import { SPORT, PersonLine } from '../sport.js';

const sum = (rows) => rows.reduce((s, x) => s + Number(x.points), 0);

export function TeamPoints({ c }) {
  const [mid, setMid] = useState(c.me?.id || c.managers[0]?.id);
  const [view, setView] = useState('season');
  const pts = useLoad(() => rpc('league_points', { p_league: c.league.id }), [c.league.id]);
  const today = new Date().toISOString().slice(0, 10);
  const started = c.matchdays.filter((md) => md.starts_on <= today);
  const [mdId, setMdId] = useState(null);
  const md = started.find((m) => m.id === mdId) || started[started.length - 1];

  if (!pts.data) return html`<${Loading} error=${pts.error} />`;
  const mine = pts.data.filter((x) => x.manager_id === mid);
  const isMe = mid === c.me?.id;
  const inRoster = (a) => c.active.some((r) => r.manager_id === mid && r[SPORT.fk] === a);

  // Zeile: Name (antippen öffnet das Profil), darunter Kurzinfo; rechts Punkte, darunter Balken für den Anteil
  const Row = ({ a, points, share, sub }) => {
    const r = c.riderMap[a];
    return html`<li class="pts-row" key=${a}>
      <span class="pts-name">
        <button type="button" class="linkish" onClick=${() => openRider(a)}>${r?.name || a}</button>
        <small class="muted"><${PersonLine} r=${r} sub=${sub} /></small>
        <span class="pts-bar"><span style=${`width:${Math.max(0, Math.min(100, share))}%`}></span></span>
      </span>
      <span class="pts-val"><strong>${fmtPts(points)}</strong><small class="muted">${Math.round(share)} %</small></span>
    </li>`;
  };

  let body;
  if (!started.length) {
    body = html`<p class="muted">Noch kein Spieltag gestartet – die Übersicht füllt sich ab dem ersten Spieltag.</p>`;
  } else if (view === 'season') {
    const total = sum(mine);
    const by = {};
    for (const x of mine) {
      by[x[SPORT.fk]] ??= { pts: 0, mds: new Set() };
      by[x[SPORT.fk]].pts += Number(x.points);
      if (Number(x.points) > 0) by[x[SPORT.fk]].mds.add(x.matchday_id);
    }
    // auch Kadermitglieder ohne Punkte zeigen (unten)
    for (const r of c.active.filter((r) => r.manager_id === mid)) by[r[SPORT.fk]] ??= { pts: 0, mds: new Set() };
    const list = Object.entries(by).sort((a, b) => b[1].pts - a[1].pts);
    body = html`<div class="row between"><span class="muted small">Saison bis heute · ${started.length} Spieltag${started.length === 1 ? '' : 'e'}</span>
        <span><span class="big">${fmtPts(total)}</span> <span class="muted small">Punkte</span></span></div>
      <ul class="list pts-list">${list.map(([a, v]) => html`<${Row} a=${a} points=${v.pts} share=${total ? (v.pts / total) * 100 : 0}
        sub=${[`an ${v.mds.size} Spieltag${v.mds.size === 1 ? '' : 'en'} gepunktet`, !inRoster(a) && 'abgegeben'].filter(Boolean).join(' · ')} />`)}</ul>`;
  } else {
    const rows = mine.filter((x) => x.matchday_id === md.id && Number(x.points) !== 0).sort((a, b) => b.points - a.points);
    const total = sum(rows);
    // Platz an diesem Spieltag im Vergleich der Teams
    const teamSums = c.managers.map((m) => sum(pts.data.filter((x) => x.manager_id === m.id && x.matchday_id === md.id)));
    const place = 1 + teamSums.filter((s) => s > total).length;
    body = html`<label>Spieltag<select value=${md.id} onChange=${(e) => setMdId(e.target.value)}>
        ${[...started].reverse().map((m) => html`<option value=${m.id}>${m.name} (${fmtDate(m.starts_on)} – ${fmtDate(m.ends_on)})</option>`)}</select></label>
      <div class="row between"><span class="muted small">Platz ${place} von ${c.managers.length} an diesem Spieltag</span>
        <span><span class="big">${fmtPts(total)}</span> <span class="muted small">Punkte</span></span></div>
      ${rows.length === 0 ? html`<p class="muted">An diesem Spieltag noch keine Punkte.</p>` : html`<ul class="list pts-list">
        ${rows.map((x) => html`<${Row} a=${x[SPORT.fk]} points=${x.points} share=${total ? (x.points / total) * 100 : 0}
          sub=${[x.overridden && 'von Hand korrigiert', !inRoster(x[SPORT.fk]) && 'inzwischen abgegeben'].filter(Boolean).join(' · ')} />`)}</ul>`}
      <p class="muted small">${SPORT.many} ohne Punkte an diesem Spieltag sind nicht aufgeführt.</p>`;
  }

  return html`<div class="stack">
    <label class="inline">Team
      <select value=${mid} onChange=${(e) => setMid(e.target.value)}>
        ${c.managers.map((x) => html`<option value=${x.id}>${x.team_name}${x.id === c.me?.id ? ' (du)' : ''}</option>`)}
      </select></label>
    <section class="card stack">
      <div class="row between"><h2>${isMe ? 'Deine Punkte' : 'Punkte'}</h2>
        <div class="seg small">
          <button class=${view === 'season' ? 'active' : ''} onClick=${() => setView('season')}>Saison</button>
          <button class=${view === 'md' ? 'active' : ''} onClick=${() => setView('md')}>Spieltag</button>
        </div></div>
      ${body}
    </section>
  </div>`;
}
