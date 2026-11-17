// Fahrer-Übersicht: alle Fahrer der Wertung mit UCI-Punkten der Saison und Besitzer in der Liga
import { html, useState, useMemo } from '../vendor/preact-htm.js';
import { rpc, useLoad, Loading, RiderCell, normName, fmtPts, withFlag, teamName, SearchSelect, rpcAll } from '../lib.js';

export function Riders({ c }) {
  const years = useLoad(() => rpc('result_years'), []);
  const [sort, setSort] = useState(String(new Date().getFullYear()));   // Jahr oder 'rank'
  // Punkte des gewählten Jahres; bei Sortierung nach UCI-Rang die des laufenden Jahres
  // gewähltes Jahr noch ohne Ergebnisse (z. B. Jahresanfang) → neuestes Jahr mit Ergebnissen
  const ys = (years.data || []).map(String);
  const recent = sort === 'recent';
  const sel = recent || sort === 'rank' || !ys.length || ys.includes(sort) ? sort : ys[0];
  const year = sel === 'rank' || recent ? +(ys[0] || new Date().getFullYear()) : +sel;
  const pts = useLoad(() => recent ? rpcAll('rider_points_recent', { p_gender: c.league.gender, p_days: 30 })
    : rpcAll('rider_points', { p_gender: c.league.gender, p_year: year }), [c.league.gender, year, recent]);
  // Heiße freie Fahrer: die 10 freien mit den meisten Punkten der letzten 30 Tage (🔥 in der Liste)
  const hot = useLoad(() => rpcAll('rider_points_recent', { p_gender: c.league.gender, p_days: 30 }), [c.league.gender]);
  const hotSet = useMemo(() => new Set((hot.data || []).filter((p) => !c.owner[p.rider_slug] && c.riderMap[p.rider_slug])
    .sort((a, b) => b.points - a.points).slice(0, 10).map((p) => p.rider_slug)), [hot.data]);
  const [term, setTerm] = useState('');
  const [team, setTeam] = useState('');
  const [nation, setNation] = useState('');
  const [owner, setOwner] = useState('');          // '' alle, 'free' frei, 'mine' meine, sonst Manager-ID
  const [limit, setLimit] = useState(100);

  const pmap = useMemo(() => Object.fromEntries((pts.data || []).map((p) => [p.rider_slug, p])), [pts.data]);
  const teams = useMemo(() => [...new Set(c.riders.map((r) => r.team).filter(Boolean))].sort(), [c.riders]);
  const nations = useMemo(() => [...new Set(c.riders.map((r) => r.nation).filter(Boolean))].sort(), [c.riders]);
  if (!pts.data) return html`<${Loading} error=${pts.error} />`;

  const t = normName(term);
  const list = c.riders
    .filter((r) => recent ? pmap[r.pcs_slug] : r.uci_rank || pmap[r.pcs_slug] || c.owner[r.pcs_slug])   // 30 Tage: nur wer gepunktet hat
    .filter((r) => (!team || normName(team).split(' ').every((w) => normName(r.team || '').includes(w))) && (!nation || r.nation === nation))
    .filter((r) => !owner || (owner === 'free' ? !c.owner[r.pcs_slug] : owner === 'mine' ? c.owner[r.pcs_slug] === c.me?.id : c.owner[r.pcs_slug] === owner))
    .filter((r) => !t || t.split(' ').every((w) => normName(r.name).includes(w)))
    .sort((a, b) => sel === 'rank'
      ? (a.uci_rank ?? 1e9) - (b.uci_rank ?? 1e9)
      : (Number(pmap[b.pcs_slug]?.points) || 0) - (Number(pmap[a.pcs_slug]?.points) || 0) || (a.uci_rank ?? 1e9) - (b.uci_rank ?? 1e9));

  return html`<section class="card">
    <div class="row between"><h2>Fahrer</h2><span class="muted small">${list.length} Fahrer · UCI-Punkte ${recent ? 'letzte 30 Tage' : year}</span></div>
    ${c.league.status === 'active' && html`<div class="row"><button class=${`small ${recent && owner === 'free' ? 'primary' : ''}`}
      onClick=${() => { if (recent && owner === 'free') { setSort(String(new Date().getFullYear())); setOwner(''); } else { setSort('recent'); setOwner('free'); } setLimit(100); }}>
      🔥 Heiße freie Fahrer</button>
      <span class="muted small">frei, meiste Punkte der letzten 30 Tage</span></div>`}
    <div class="filters">
      <input type="search" placeholder="Name" value=${term} onInput=${(e) => { setTerm(e.target.value); setLimit(100); }} />
      <${SearchSelect} value=${team} onChange=${setTeam} options=${teams} label=${teamName} placeholder="Team (z. B. UAE)" />
      <select value=${nation} onChange=${(e) => setNation(e.target.value)}><option value="">Alle Nationen</option>${nations.map((x) => html`<option value=${x}>${withFlag(x)}</option>`)}</select>
      <select value=${owner} onChange=${(e) => setOwner(e.target.value)}>
        <option value="">Alle Fahrer</option><option value="free">Nur freie</option>
        ${c.me && html`<option value="mine">Mein Kader</option>`}
        ${c.managers.filter((m) => m.id !== c.me?.id).map((m) => html`<option value=${m.id}>Kader ${m.team_name}</option>`)}
      </select>
      <select value=${sel} onChange=${(e) => setSort(e.target.value)}>
        ${(years.data?.length ? years.data : [year]).map((yy) => html`<option value=${String(yy)}>Sortiert nach Punkten ${yy}</option>`)}
        <option value="recent">Sortiert nach Punkten letzte 30 Tage</option>
        <option value="rank">Sortiert nach UCI-Rang (aktuell)</option>
      </select>
    </div>
    <div class="scroll-x"><table class="tbl riders-tbl">
      <thead><tr><th class="num hide-sm col-no">#</th><th>Fahrer</th><th class="col-owner">Kader</th><th class="num hide-sm col-res">Ergebnisse</th><th class="num col-pts" title=${recent ? 'UCI-Punkte der letzten 30 Tage' : `UCI-Punkte ${year}`}>Pkt.</th></tr></thead>
      <tbody>${list.slice(0, limit).map((r, i) => {
        const m = c.managerMap[c.owner[r.pcs_slug]];
        const p = pmap[r.pcs_slug];
        return html`<tr key=${r.pcs_slug} class=${m && m.id === c.me?.id ? 'me' : ''}>
          <td class="num muted hide-sm">${i + 1}</td>
          <td><${RiderCell} r=${r} /></td>
          <td class="col-owner">${m ? m.team_name : html`<span class="tag ok">frei</span>${hotSet.has(r.pcs_slug) ? html` <span title="Heiß: unter den 10 freien Fahrern mit den meisten Punkten der letzten 30 Tage">🔥</span>` : ''}`}</td>
          <td class="num hide-sm">${p?.results || 0}</td>
          <td class="num"><strong>${Math.round(Number(p?.points) || 0).toLocaleString('de-DE')}</strong></td></tr>`;
      })}</tbody>
    </table></div>
    ${list.length > limit && html`<div class="row"><button onClick=${() => setLimit(limit + 200)}>Mehr anzeigen (${list.length - limit} weitere)</button></div>`}
    ${(pts.data || []).length === 0 && html`<p class="muted small">Noch keine Ergebnisse ${recent ? 'in den letzten 30 Tagen' : 'für dieses Jahr'} – Rennergebnisse werden täglich um 20 Uhr abgerufen.</p>`}
  </section>`;
}
