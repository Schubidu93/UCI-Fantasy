// Liga-Übersicht (Startseite einer Liga): Fristen, Tabelle kurz, mein Kader, letzte Punkte, offene Tausche
import { html } from '../vendor/preact-htm.js';
import { NextDeadline } from './deadline.js';
import { fmtDate, fmtPts, Loading, openRider, q, rpc, rpcAll, sb, useLoad } from '../lib.js';
import { labelText, SPORT } from '../sport/index.js';

export function Overview({ c }) {
  const L = c.league.id;
  const href = (t) => `#/league/${L}/${t}`;
  const year = new Date().getFullYear();
  const mine = c.me ? c.active.filter((r) => r.manager_id === c.me.id) : [];
  const data = useLoad(async () => {
    const since = new Date(Date.now() - 14 * 864e5).toISOString().slice(0, 10);
    const slugs = mine.map((r) => r.athlete_id);
    const [table, pts, recent, trades] = await Promise.all([
      c.league.status === 'active' || c.league.status === 'finished' ? rpc('league_table', { p_league: L }) : [],
      rpcAll('athlete_points', { p_gender: c.league.gender, p_year: year }),
      slugs.length ? q(sb.from('results').select(`athlete_id,competition_id,label,result_date,points`)
        .in('athlete_id', slugs).gte('result_date', since).order('result_date', { ascending: false }).limit(12)) : [],
      c.me ? q(sb.from('trades').select('id').eq('league_id', L).eq('to_manager', c.me.id).eq('status', 'proposed')) : [],
    ]);
    return { table, pts: Object.fromEntries(pts.map((p) => [p.athlete_id, Number(p.points)])), recent, trades };
  }, [L, c.me?.id, mine.length]);
  if (!data.data) return html`<${Loading} error=${data.error} />`;
  const { table, pts, recent, trades } = data.data;
  const before = ['setup', 'drafting'].includes(c.league.status);
  const myRow = table.find((r) => r.manager_id === c.me?.id);
  const name = (s) => c.riderMap[s]?.name || s;

  return html`<div class="stack">
    ${before && html`<section class="card">
      <h3>${c.league.status === 'drafting' ? `${SPORT.emoji} Der Draft läuft` : 'Vor dem Draft'}</h3>
      <p class="muted">${c.league.status === 'drafting' ? 'Ab in den Draft-Raum!' : 'Sobald der Draft vorbei ist, siehst du hier Tabelle, Kader und neue Punkte.'}</p>
      <a class="button primary" href=${href('draft')}>Zum Draft</a></section>`}
    <${NextDeadline} c=${c} compact />
    ${trades.length > 0 && html`<a class="card link note-card" href=${href('team')}><strong>🔁 ${trades.length} offenes Tauschangebot${trades.length > 1 ? 'e' : ''}</strong>
      <span class="muted small">Annehmen oder ablehnen unter Team → Kader</span></a>`}

    ${!before && html`<section class="card">
      <div class="row between"><h3>Tabelle</h3><a class="small" href=${href('table')}>Alle →</a></div>
      ${table.length === 0 ? html`<p class="muted small">Noch keine Punkte – die Tabelle füllt sich ab dem ersten Spieltag.</p>`
        : html`<table class="tbl"><tbody>${table.slice(0, 3).concat(myRow && myRow.position > 3 ? [myRow] : []).map((r) => html`
          <tr key=${r.manager_id} class=${r.manager_id === c.me?.id ? 'me' : ''}><td>${r.position}.</td><td>${r.team_name}</td>
            <td class="num"><strong>${fmtPts(r.total)}</strong></td></tr>`)}</tbody></table>`}
    </section>`}

    ${c.me && mine.length > 0 && html`<section class="card">
      <div class="row between"><h3>Mein Kader</h3><a class="small" href=${href('team')}>Kader →</a></div>
      <ul class="list compact">${[...mine].sort((a, b) => (pts[b.athlete_id] || 0) - (pts[a.athlete_id] || 0)).map((r) => html`<li key=${r.id}>
        <button class="linkish" onClick=${() => openRider(r.athlete_id)}>${name(r.athlete_id)}</button>
        <span class="muted">${fmtPts(pts[r.athlete_id] || 0)} Pkt. ${year}</span></li>`)}</ul>
    </section>`}

    ${c.me && mine.length > 0 && html`<section class="card">
      <h3>Neue Punkte meiner ${SPORT.many}</h3>
      ${recent.length === 0 ? html`<p class="muted small">In den letzten 14 Tagen keine Punkte – ${SPORT.resultsSchedule}</p>`
        : html`<ul class="list compact">${recent.map((r, i) => html`<li key=${i}>
          <span><strong>${name(r.athlete_id)}</strong> <span class="muted small">${labelText(r.label)}</span></span>
          <span class="muted">${fmtDate(r.result_date)} · <strong>+${fmtPts(r.points)}</strong></span></li>`)}</ul>`}
    </section>`}
  </div>`;
}
