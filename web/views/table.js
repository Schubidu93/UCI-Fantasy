import { html, useState } from '../vendor/preact-htm.js';
import { rpc, useLoad, Loading, fmtPts, fmtDate, draftCosts } from '../lib.js';

const COLORS = ['#2a6fdb', '#e8590c', '#2f9e44', '#c2255c', '#7048e8', '#0c8599', '#f08c00', '#5c940d',
  '#d6336c', '#1971c2', '#e67700', '#087f5b', '#9c36b5', '#c92a2a', '#364fc7', '#66a80f', '#a61e4d', '#0b7285', '#5f3dc4', '#862e9c'];

export function Table({ c }) {
  const table = useLoad(() => rpc('league_table', { p_league: c.league.id }), [c.league.id]);
  const pts = useLoad(() => rpc('league_points', { p_league: c.league.id }), [c.league.id]);
  const [view, setView] = useState('total');
  if (!table.data || !pts.data) return html`<${Loading} error=${table.error || pts.error} />`;

  const mds = c.matchdays.filter((m) => m.status !== 'planned');
  const faab = c.league.waiver_mode === 'faab';   // Budget zählt nach dem Draft nur noch für FAAB-Gebote
  const sum = (mid, md) => pts.data.filter((p) => p.manager_id === mid && p.matchday_id === md).reduce((s, p) => s + Number(p.points), 0);

  const empty = !c.matchdays.some((m) => m.starts_on <= new Date().toISOString().slice(0, 10));
  return html`<div class="stack">
    ${empty && html`<p class="note small">${c.matchdays.length
      ? `Die Tabelle füllt sich ab dem ersten Spieltag (${c.matchdays[0].name}, ab ${fmtDate(c.matchdays[0].starts_on)}).`
      : 'Noch keine Spieltage angelegt – ohne Spieltage gibt es keine Punkte.'}${!c.matchdays.length && c.isAdmin ? html` <a href=${`#/league/${c.league.id}/admin`}>Spieltage anlegen →</a>` : ''}</p>`}
    <section class="card">
      <div class="row between"><h2>Tabelle</h2>
        <div class="seg small">
          <button class=${view === 'total' ? 'active' : ''} onClick=${() => setView('total')}>Gesamt</button>
          <button class=${view === 'md' ? 'active' : ''} onClick=${() => setView('md')}>Pro Spieltag</button>
        </div></div>
      ${view === 'total' ? html`<table class="tbl">
        <thead><tr><th>#</th><th>Team</th><th class="num">Punkte</th><th class="num" title="Spieltagssiege">Siege</th>
          <th class="num" title="bester Spieltag">Bester</th>${faab && html`<th class="num" title="Restbudget für FAAB-Gebote">Budget</th>`}</tr></thead>
        <tbody>${table.data.map((r) => html`<tr key=${r.manager_id} class=${r.manager_id === c.me?.id ? 'me' : ''}>
          <td>${r.position}</td><td>${r.team_name}</td><td class="num"><strong>${fmtPts(r.total)}</strong></td>
          <td class="num">${r.matchday_wins}</td><td class="num">${fmtPts(r.best_matchday)}</td>${faab && html`<td class="num">${c.managerMap[r.manager_id]?.budget_left}</td>`}</tr>`)}</tbody>
      </table>
      <p class="muted small">Gleichstand: zuerst mehr Spieltagssiege, dann höchster Einzelspieltag${draftCosts(c.league) ? ', dann weniger ausgegebenes Budget' : ''}.</p>`
      : html`<div class="scroll-x"><table class="tbl">
        <thead><tr><th>Team</th>${mds.map((m) => html`<th class="num">${m.name}</th>`)}</tr></thead>
        <tbody>${table.data.map((r) => {
          return html`<tr key=${r.manager_id} class=${r.manager_id === c.me?.id ? 'me' : ''}><td>${r.team_name}</td>
            ${mds.map((m) => {
              const v = sum(r.manager_id, m.id);
              const best = Math.max(...table.data.map((x) => sum(x.manager_id, m.id)));
              return html`<td class=${`num ${v > 0 && v === best ? 'win' : ''}`}>${fmtPts(v)}</td>`;
            })}</tr>`;
        })}</tbody></table></div>`}
    </section>
    ${mds.length > 0 && html`<section class="card"><h3>Verlauf</h3><${Chart} c=${c} teams=${table.data} mds=${mds} sum=${sum} /></section>`}
  </div>`;
}

// Kumulierte Punkte pro Spieltag als Linien
function Chart({ c, teams, mds, sum }) {
  const W = 640, H = 260, P = { l: 44, r: 12, t: 12, b: 28 };
  const series = teams.map((t, i) => {
    let acc = 0;
    return { t, color: COLORS[i % COLORS.length], pts: [0, ...mds.map((m) => (acc += sum(t.manager_id, m.id)))] };
  });
  const max = Math.max(1, ...series.flatMap((s) => s.pts));
  const x = (i) => P.l + (i * (W - P.l - P.r)) / Math.max(1, mds.length);
  const y = (v) => H - P.b - (v / max) * (H - P.t - P.b);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => Math.round(max * f));
  return html`<svg viewBox=${`0 0 ${W} ${H}`} class="chart" role="img" aria-label="Punkteverlauf">
    ${ticks.map((v) => html`<g><line x1=${P.l} x2=${W - P.r} y1=${y(v)} y2=${y(v)} class="grid" />
      <text x=${P.l - 6} y=${y(v) + 4} text-anchor="end" class="axis">${v.toLocaleString('de-DE')}</text></g>`)}
    ${mds.map((m, i) => html`<text x=${x(i + 1)} y=${H - 8} text-anchor="middle" class="axis">${m.name.slice(0, 12)}</text>`)}
    ${series.map((s) => html`<polyline fill="none" stroke=${s.color} stroke-width=${s.t.manager_id === c.me?.id ? 3 : 1.6}
      points=${s.pts.map((v, i) => `${x(i)},${y(v)}`).join(' ')}><title>${s.t.team_name}</title></polyline>`)}
  </svg>
  <ul class="legend">${series.map((s) => html`<li><span style=${`background:${s.color}`}></span>${s.t.team_name}</li>`)}</ul>`;
}
