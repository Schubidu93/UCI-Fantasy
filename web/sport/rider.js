// Fahrer-Fenster: Stammdaten und alle Ergebnisse (Rang, Zeit, UCI-Punkte) – Klick springt ins Rennen
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { sb, q, all, fmtPts, flag, teamName } from '../lib.js';
import { describeEvent } from './races.js';

// Ergebnisse werden ab dieser Saison geladen; ältere Einzeldaten sind lückenhaft und werden nicht angezeigt
const FIRST_YEAR = 2025;

// Zwischenstand einer Rundfahrt nach einer Etappe, z. B. „Etappe 7 · GC“
const isInterim = (x) => /^(Etappe \d+|Prolog) · /.test(describeEvent(x.ev.stage_name, x.ev.event_name));
// Berg-, Punkte- und Nebenwertungen nach einzelnen Etappen ohne UCI-Punkte – nur die Endwertung zählt
const interimSide = (x) => isInterim(x) && !/ · GC$/.test(describeEvent(x.ev.stage_name, x.ev.event_name)) && !Number(x.uci_points);

// Eintagesrennen (Klasse 1.x) haben kein GC – dort heißt die Wertung „Ergebnis“
const label = (x) => {
  const l = describeEvent(x.ev.stage_name, x.ev.event_name);
  return l === 'GC' && /^1\./.test(x.race?.uci_class || '') ? 'Ergebnis' : l;
};

// Platz 1–3 als Gold/Silber/Bronze – nicht bei Zwischenständen in Rundfahrten (z. B. „Etappe 7 · GC“)
function placeLabel(x) {
  if (x.rank_text && !/^\d+$/.test(x.rank_text)) return html`<span class="muted">${x.rank_text}</span>`;
  if (!x.rank) return '';
  return x.rank <= 3 && !isInterim(x) ? html`<span class=${`medal m${x.rank}`}>${x.rank}.</span>` : `${x.rank}.`;
}
// „28.08.“ – das Jahr steht schon oben im Reiter
const shortDate = (d) => (d ? `${d.slice(8, 10)}.${d.slice(5, 7)}.` : '');

const leagueId = () => (location.hash.match(/^#\/league\/([^/]+)/) || [])[1];

async function loadRider(slug) {
  const [rider] = await q(sb.from('riders').select('*').eq('pcs_slug', slug));
  const rows = await all(() => sb.from('event_results').select('event_id,rank,rank_text,result,uci_points')
    .eq('rider_slug', slug).order('event_id'));
  const ids = [...new Set(rows.map((r) => r.event_id))];
  const events = {};
  for (let i = 0; i < ids.length; i += 150) {
    for (const e of await q(sb.from('race_events').select('id,race_slug,stage_name,stage_no,event_name,event_date').in('id', ids.slice(i, i + 150)))) events[e.id] = e;
  }
  const slugs = [...new Set(Object.values(events).map((e) => e.race_slug))];
  const races = {};
  for (let i = 0; i < slugs.length; i += 100) {
    for (const r of await q(sb.from('races').select('pcs_slug,name,uci_class,start_date,season').in('pcs_slug', slugs.slice(i, i + 100)))) races[r.pcs_slug] = r;
  }
  // Saisonplätze aller Jahre direkt mitladen (fest gespeichert, keine Berechnung nötig)
  const season = Object.fromEntries((await q(sb.from('rider_season_stats').select('year,season_rank,points,riders').eq('rider_slug', slug)))
    .map((x) => [x.year, x]));
  const results = rows.filter((r) => events[r.event_id]).map((r) => ({ ...r, ev: events[r.event_id], race: races[events[r.event_id].race_slug] }));
  return { rider, results, season };
}

export function RiderModal() {
  const [slug, setSlug] = useState(null);
  const [year, setYear] = useState(null);
  const [allPlaces, setAllPlaces] = useState(false);
  const [byPoints, setByPoints] = useState(false);   // false = nach Datum (je Rennen), true = beste Ergebnisse zuerst
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const open = (e) => { setSlug(e.detail); setData(null); setError(null); setYear(null); setByPoints(false); };
    const esc = (e) => { if (e.key === 'Escape') setSlug(null); };
    addEventListener('rider:open', open);
    addEventListener('keydown', esc);
    return () => { removeEventListener('rider:open', open); removeEventListener('keydown', esc); };
  }, []);

  useEffect(() => {
    if (!slug) return;
    let alive = true;
    loadRider(slug).then((d) => alive && setData(d)).catch((e) => alive && setError(e.message));
    return () => { alive = false; };
  }, [slug]);

  const r = data?.rider;
  // Kalenderjahr des Ergebnisses
  const yearOf = (x) => +(x.ev.event_date || x.race?.start_date || '0').slice(0, 4);
  const withPoints = (data?.results || []).filter((x) => Number(x.uci_points) > 0);
  const years = [...new Set(withPoints.map(yearOf))].filter((yy) => yy >= FIRST_YEAR).sort();
  const thisYear = new Date().getFullYear();
  const y = year || (years.includes(thisYear) ? thisYear : years[years.length - 1]);
  const shown = (allPlaces ? data?.results || [] : withPoints).filter((x) => yearOf(x) === y && !interimSide(x))
    .sort((a, b) => (b.ev.event_date || '').localeCompare(a.ev.event_date || '') || a.ev.id - b.ev.id);
  const total = withPoints.filter((x) => yearOf(x) === y).reduce((s, x) => s + Number(x.uci_points), 0);
  // Oben immer die aktuelle UCI-Weltrangliste, darunter Punkte und Platz im gewählten Jahr
  const sr = data?.season?.[y];
  const rankLine = r && (r.uci_rank ? `UCI-Rang ${r.uci_rank} · ${fmtPts(r.ranking_points)} Ranking-Punkte` : 'Kein aktueller UCI-Rang');
  const yearLine = y && `${y}: ${fmtPts(total)} Punkte${sr ? ` · Platz ${sr.season_rank}` : ''}`;
  const groups = [];
  for (const x of shown) {
    let g = groups.find((g) => g.slug === x.ev.race_slug);
    if (!g) groups.push(g = { slug: x.ev.race_slug, race: x.race, rows: [], sum: 0 });
    g.rows.push(x); g.sum += Number(x.uci_points) || 0;
  }
  // Beste Ergebnisse: jedes einzelne Ergebnis mit Punkten, absteigend
  const best = withPoints.filter((x) => yearOf(x) === y)
    .sort((a, b) => Number(b.uci_points) - Number(a.uci_points) || (b.ev.event_date || '').localeCompare(a.ev.event_date || ''));
  const L = leagueId();
  const row = (x, withRace) => html`<div key=${x.event_id} class=${`res-row ${L ? 'clickable' : ''} ${isInterim(x) ? 'interim' : ''}`} onClick=${() => go(x)} title=${L ? 'Ganzes Ergebnis anzeigen' : ''}>
    <span class="res-date">${shortDate(x.ev.event_date)}</span>
    <span class="res-what">${withRace
      ? html`<b>${x.race?.name || x.ev.race_slug}</b><small>${label(x)}${x.result ? ` · ${x.result}` : ''}</small>`
      : html`${label(x)}${x.result ? html`<small>${x.result}</small>` : ''}`}</span>
    <span class="res-place">${placeLabel(x)}</span>
    <span class="res-pts">${Number(x.uci_points) ? fmtPts(x.uci_points) : ''}</span>
  </div>`;
  const go = (x) => { if (!L) return; setSlug(null); location.hash = `#/league/${L}/races/${encodeURIComponent(x.ev.race_slug)}/${x.ev.id}`; };

  if (!slug) return null;
  return html`<div class="modal-back" onClick=${() => setSlug(null)}>
    <div class="modal card" role="dialog" aria-modal="true" aria-label="Fahrer" onClick=${(e) => e.stopPropagation()}>
      <div class="modal-head">
        <div class="modal-title">
          <h2>${r?.nation ? flag(r.nation) + ' ' : ''}${r?.name || '…'}</h2>
          ${r && html`<div class="muted small">${[r.nation && r.nation.trim(),
            r.birth_date && `${r.birth_date.slice(0, 4)} (${Math.floor((Date.now() - new Date(r.birth_date)) / 31557600000)} J.)`,
            teamName(r.team)].filter(Boolean).join(' · ')}</div>`}
          ${rankLine && html`<div class="small"><strong>${rankLine}</strong></div>`}
          ${yearLine && html`<div class="small">${yearLine}</div>`}
        </div>
        <button class="ghost small" onClick=${() => setSlug(null)} aria-label="Schließen">✕</button>
      </div>
      ${error ? html`<p class="note err">${error}</p>` : !data ? html`<p class="muted">Lädt …</p>` : html`
        <div class="row between">
          ${years.length > 1 ? html`<div class="seg small">${years.map((yy) =>
            html`<button class=${yy === y ? 'active' : ''} onClick=${() => setYear(yy)}>${yy}</button>`)}</div>` : html`<span class="muted small">${y || ''}</span>`}
          <div><span class="big">${fmtPts(total)}</span> <span class="muted small">UCI-Punkte${y ? ` ${y}` : ''}</span></div>
        </div>
        <div class="row between">
          <label class="sort-select small">Sortieren:
            <select value=${byPoints ? 'points' : 'date'} onChange=${(e) => setByPoints(e.target.value === 'points')}>
              <option value="date">nach Datum</option>
              <option value="points">nach Punkten</option>
            </select>
          </label>
          ${!byPoints && html`<label class="check small"><input type="checkbox" checked=${allPlaces} onChange=${(e) => setAllPlaces(e.target.checked)} /> ohne Punkte</label>`}
        </div>
        ${(byPoints ? best : shown).length === 0 ? html`<p class="muted">Keine Ergebnisse${y ? ` in ${y}` : ''}.</p>` : html`<div class="modal-body">
          <div class="res-row res-head">
            <button class=${`linkish ${!byPoints ? 'sorted' : ''}`} onClick=${() => setByPoints(false)}>Datum${!byPoints ? ' ▾' : ''}</button>
            <span>${byPoints ? 'Rennen · Wertung' : 'Wertung · Zeit'}</span><span class="res-place">Platz</span>
            <button class=${`linkish res-pts ${byPoints ? 'sorted' : ''}`} onClick=${() => setByPoints(true)}>Pkt.${byPoints ? ' ▾' : ''}</button>
          </div>
          ${byPoints
            ? html`<div class="res-table">${best.map((x) => row(x, true))}</div>`
            : groups.map((g) => html`<div class="detail-rider" key=${g.slug}>
              <div class="row between"><strong>${g.race?.name || g.slug}${g.race?.uci_class ? html` <span class="tag">${g.race.uci_class}</span>` : ''}</strong>
                <span>${g.sum ? fmtPts(g.sum) : ''}</span></div>
              <div class="res-table">${g.rows.map((x) => row(x, false))}</div>
            </div>`)}
        </div>`}`}
      <p class="muted small">Quelle: UCI DataRide. Antippen öffnet das ganze Ergebnis.</p>
    </div>
  </div>`;
}
