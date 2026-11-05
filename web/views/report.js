// Draft-Board und Draft-Report (Note A+ bis F, Prognose, Steal und Reach) – nach dem Draft
import { html, useState } from '../vendor/preact-htm.js';
import { sb, all, rpc, useLoad, Loading, RiderCell, fmtPts, draftCosts, rpcAll } from '../lib.js';

const GRADES = [[1.35, 'A+'], [1.25, 'A'], [1.15, 'A−'], [1.08, 'B+'], [1.0, 'B'], [0.93, 'B−'],
  [0.86, 'C+'], [0.8, 'C'], [0.74, 'C−'], [0.65, 'D'], [0, 'F']];
const grade = (ratio) => GRADES.find(([min]) => ratio >= min)[1];
const gradeClass = (g) => ({ A: 'g-a', B: 'g-b', C: 'g-c', D: 'g-d', F: 'g-f' }[g[0]]);

const INTRO = {
  A: ['Ein Draft zum Einrahmen.', 'Hier hat jemand seine Hausaufgaben gemacht.', 'Die Konkurrenz darf sich warm anziehen.'],
  B: ['Solide Arbeit mit klarem Plan.', 'Ein Kader, mit dem man vorne mitfahren kann.', 'Kein Feuerwerk, aber viel Substanz.'],
  C: ['Licht und Schatten.', 'Ein Kader mit Luft nach oben.', 'Mittelfeld – mit etwas Glück geht mehr.'],
  D: ['Das wird eine lange Saison.', 'Viele Fragezeichen im Kader.', 'Hier muss der Waiver-Draht glühen.'],
  F: ['Mutig. Sehr mutig.', 'Ein Draft für die Geschichtsbücher – leider nicht im guten Sinne.', 'Auf diesen Kader wettet niemand.'],
};
const pick = (arr, seed) => arr[Math.abs(seed) % arr.length];
const hash = (s) => [...s].reduce((h, ch) => (h * 31 + ch.charCodeAt(0)) | 0, 7);

// Berechnet Board und Report aus den Draft-Picks und den Vorjahrespunkten
export function buildReport(c, lots, pts, proj = null) {
  const picks = lots.filter((l) => l.manager_id).sort((a, b) => a.lot_no - b.lot_no || a.id - b.id);
  const value = (slug) => Number(pts[slug] || 0);
  // erwartete Pick-Position nach Vorjahrespunkten (1 = wertvollster gezogener Fahrer)
  const byValue = [...picks].sort((a, b) => value(b.rider_slug) - value(a.rider_slug));
  const expected = Object.fromEntries(byValue.map((p, i) => [p.rider_slug, i + 1]));
  const auction = draftCosts(c.league);
  let no = 0;
  picks.forEach((p) => {
    p.keeper = p.lot_no === 0;                       // Keeper aus der Vorsaison zählen mit, sind aber kein Pick
    p.pickNo = p.keeper ? null : ++no;
    p.value = value(p.rider_slug);
    // Snake: späte Picks mit vielen Punkten = Steal; Auktion: Punkte pro Budgetpunkt
    p.delta = p.keeper ? 0 : auction ? p.value / Math.max(1, p.price) : p.pickNo - expected[p.rider_slug];
  });
  const teams = c.managers.map((m) => {
    const mine = picks.filter((p) => p.manager_id === m.id);
    // Bewertung: bestmögliche Aufstellung je Spieltag im Vorjahr (aus der Datenbank), sonst Summe der Punkte
    const sum = mine.reduce((s, p) => s + p.value, 0);
    return { m, picks: mine, total: proj ? Number(proj[m.id] || 0) : sum, sum, spent: mine.reduce((s, p) => s + (p.price || 0), 0) };
  });
  const avg = teams.reduce((s, t) => s + t.total, 0) / Math.max(1, teams.length) || 1;
  teams.sort((a, b) => b.total - a.total);
  teams.forEach((t, i) => {
    t.rank = i + 1;
    t.grade = grade(t.total / avg);
    const withPts = t.picks.filter((p) => p.value > 0);
    const real = t.picks.filter((p) => !p.keeper);
    t.steal = [...real].sort((a, b) => b.delta - a.delta)[0];
    t.reach = auction
      ? [...real].filter((p) => p.price > 1).sort((a, b) => a.delta - b.delta)[0]
      : [...real].sort((a, b) => a.delta - b.delta)[0];
    if (t.reach && t.steal && t.reach.rider_slug === t.steal.rider_slug) t.reach = null;
    const name = (p) => c.riderMap[p.rider_slug]?.name || p.rider_slug;
    const round = (p) => Math.ceil(p.pickNo / Math.max(1, c.managers.length));
    const seed = hash(t.m.id);
    const parts = [pick(INTRO[t.grade[0]], seed)];
    parts.push(proj
      ? `Mit der besten Aufstellung hätte dieser Kader im Vorjahr ${fmtPts(t.total)} Punkte geholt – Prognose-Platz ${t.rank} von ${teams.length}.`
      : `Mit ${fmtPts(t.total)} Punkten aus dem Vorjahr reicht es für Prognose-Platz ${t.rank} von ${teams.length}.`);
    if (t.steal && t.steal.value > 0) {
      parts.push(auction
        ? `Bester Einkauf: ${name(t.steal)} für ${t.steal.price} – ${fmtPts(t.steal.value)} Vorjahrespunkte.`
        : `Steal: ${name(t.steal)} in Runde ${round(t.steal)} (Pick ${t.steal.pickNo}) mit ${fmtPts(t.steal.value)} Vorjahrespunkten.`);
    }
    if (t.reach && t.reach.delta < (auction ? 20 : -1)) {
      parts.push(auction
        ? `Teuerstes Fragezeichen: ${name(t.reach)} für ${t.reach.price} bei nur ${fmtPts(t.reach.value)} Punkten.`
        : `Reach: ${name(t.reach)} schon an Pick ${t.reach.pickNo} – nur ${fmtPts(t.reach.value)} Vorjahrespunkte.`);
    }
    if (!withPts.length) parts.push('Kein einziger Fahrer mit Vorjahrespunkten – ein echtes Wagnis.');
    t.text = parts.join(' ');
  });
  return { picks, teams };
}

export function DraftReport({ c }) {
  const L = c.league.id;
  const prevYear = +c.league.season_start.slice(0, 4) - 1;
  const data = useLoad(async () => {
    const lots = await all(() => sb.from('draft_lots').select('*').eq('league_id', L).order('lot_no'));
    let pts = Object.fromEntries((await rpcAll('rider_points', { p_gender: c.league.gender, p_year: prevYear }))
      .map((r) => [r.rider_slug, Number(r.points)]));
    let basis = `Punkte ${prevYear}`;
    // bestmögliche Punkte je Kader (Top x aus y je Spieltag im Vorjahr) – serverseitig zwischengespeichert
    const rows = await rpc('draft_projection', { p_league: L }).catch(() => []);
    let proj = rows.some((r) => Number(r.points) > 0) ? Object.fromEntries(rows.map((r) => [r.manager_id, Number(r.points)])) : null;
    // Ohne Vorjahresdaten: aktuelle UCI-Ranglistenpunkte (52 Wochen) als Maßstab
    if (!lots.some((l) => pts[l.rider_slug])) {
      pts = Object.fromEntries(c.riders.map((r) => [r.pcs_slug, Number(r.ranking_points || 0)]));
      basis = 'UCI-Ranglistenpunkte';
      proj = null;
    }
    return { lots, pts, basis, proj };
  }, [L, prevYear]);
  const [view, setView] = useState('report');
  if (!data.data) return html`<${Loading} error=${data.error} />`;
  const { picks, teams } = buildReport(c, data.data.lots, data.data.pts, data.data.proj);
  const auction = draftCosts(c.league);
  const name = (slug) => c.riderMap[slug];
  const n = Math.max(1, c.managers.length);

  return html`<div class="stack">
    <section class="card">
      <div class="row between"><h2>Draft-Report</h2>
        <div class="seg small">
          <button class=${view === 'report' ? 'active' : ''} onClick=${() => setView('report')}>Noten</button>
          <button class=${view === 'board' ? 'active' : ''} onClick=${() => setView('board')}>Draft-Board</button>
          <button class=${view === 'teams' ? 'active' : ''} onClick=${() => setView('teams')}>Kader</button>
        </div></div>
      <p class="muted small">${data.data.proj
        ? `Bewertet nach den Punkten ${prevYear}: je Spieltag (gleicher Zeitraum im Vorjahr) zählen die besten ${c.league.scoring_mode === 'lineup' ? c.league.lineup_size : c.league.roster_size} der ${c.league.roster_size} Fahrer jedes Kaders.`
        : `Bewertet nach ${data.data.basis} der gezogenen Fahrer.`} Eine Prognose, keine Garantie.</p>
    </section>

    ${view === 'report' && teams.map((t) => html`<section class=${`card report ${t.m.id === c.me?.id ? 'mine' : ''}`} key=${t.m.id}>
      <div class="report-head">
        <div class=${`grade ${gradeClass(t.grade)}`}>${t.grade}</div>
        <div class="report-title">
          <h3>${t.m.team_name}</h3>
          <div class="muted small">Prognose: Platz ${t.rank} · ${fmtPts(t.total)} ${data.data.proj ? `Pkt. (beste Aufstellung ${prevYear})` : data.data.basis}${auction ? ` · ${t.spent} Budget` : ''}</div>
        </div>
      </div>
      <p>${t.text}</p>
    </section>`)}

    ${view === 'board' && html`<section class="card"><div class="scroll-x"><table class="tbl">
      <thead><tr><th class="num">Pick</th>${!auction && html`<th class="num hide-sm">Runde</th>`}<th>Fahrer</th><th>Team</th>
        ${auction && html`<th class="num">Preis</th>`}<th class="num">Pkt. ${data.data.basis === 'UCI-Ranglistenpunkte' ? 'Rangl.' : prevYear}</th></tr></thead>
      <tbody>${picks.map((p) => html`<tr key=${p.id} class=${p.manager_id === c.me?.id ? 'me' : ''}>
        <td class="num">${p.keeper ? 'K' : p.pickNo}</td>${!auction && html`<td class="num hide-sm">${Math.ceil(p.pickNo / n)}</td>`}
        <td><${RiderCell} r=${name(p.rider_slug)} /></td>
        <td class="small">${c.managerMap[p.manager_id]?.team_name}</td>
        ${auction && html`<td class="num">${p.price}</td>`}
        <td class="num"><strong>${fmtPts(p.value)}</strong></td></tr>`)}</tbody>
    </table></div><p class="muted small">K = Keeper aus der Vorsaison.</p></section>`}

    ${view === 'teams' && html`<div class="cards">${teams.map((t) => html`<div class="card" key=${t.m.id}>
      <div class="row between"><h3>${t.m.team_name}</h3><span class=${`grade small ${gradeClass(t.grade)}`}>${t.grade}</span></div>
      <ul class="list compact">${t.picks.map((p) => html`<li key=${p.id}>
        <span><span class="muted">${p.keeper ? 'K' : `#${p.pickNo}`}</span> ${name(p.rider_slug)?.name || p.rider_slug}</span>
        <span class="muted">${auction ? `${p.price} · ` : ''}${fmtPts(p.value)}</span></li>`)}</ul>
    </div>`)}</div>`}
  </div>`;
}
