// Fahrer-Fenster: Stammdaten und alle Ergebnisse (Rang, Zeit, UCI-Punkte) – Klick springt ins Rennen
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { sb, q, all, fmtDate, fmtPts, flag, withFlag } from '../lib.js';
import { describeEvent } from './races.js';

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
    for (const r of await q(sb.from('races').select('pcs_slug,name,uci_class,start_date').in('pcs_slug', slugs.slice(i, i + 100)))) races[r.pcs_slug] = r;
  }
  const results = rows.filter((r) => events[r.event_id]).map((r) => ({ ...r, ev: events[r.event_id], race: races[events[r.event_id].race_slug] }));
  return { rider, results };
}

export function RiderModal() {
  const [slug, setSlug] = useState(null);
  const [year, setYear] = useState(null);
  const [allPlaces, setAllPlaces] = useState(false);
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const open = (e) => { setSlug(e.detail); setData(null); setError(null); setYear(null); };
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

  if (!slug) return null;
  const r = data?.rider;
  const yearOf = (x) => +(x.ev.event_date || x.race?.start_date || '0').slice(0, 4);
  const withPoints = (data?.results || []).filter((x) => Number(x.uci_points) > 0);
  const years = [...new Set(withPoints.map(yearOf))].filter(Boolean).sort();
  const thisYear = new Date().getFullYear();
  const y = year || (years.includes(thisYear) ? thisYear : years[years.length - 1]);
  const shown = (allPlaces ? data?.results || [] : withPoints).filter((x) => yearOf(x) === y)
    .sort((a, b) => (b.ev.event_date || '').localeCompare(a.ev.event_date || '') || a.ev.id - b.ev.id);
  const total = withPoints.filter((x) => yearOf(x) === y).reduce((s, x) => s + Number(x.uci_points), 0);
  const groups = [];
  for (const x of shown) {
    let g = groups.find((g) => g.slug === x.ev.race_slug);
    if (!g) groups.push(g = { slug: x.ev.race_slug, race: x.race, rows: [], sum: 0 });
    g.rows.push(x); g.sum += Number(x.uci_points) || 0;
  }
  const L = leagueId();
  const go = (x) => { if (!L) return; setSlug(null); location.hash = `#/league/${L}/races/${encodeURIComponent(x.ev.race_slug)}/${x.ev.id}`; };

  return html`<div class="modal-back" onClick=${() => setSlug(null)}>
    <div class="modal card" role="dialog" aria-modal="true" aria-label="Fahrer" onClick=${(e) => e.stopPropagation()}>
      <div class="modal-head">
        <div class="modal-title">
          <h2>${r?.nation ? flag(r.nation) + ' ' : ''}${r?.name || '…'}</h2>
          ${r && html`<div class="muted small">${[r.team, r.nation && withFlag(r.nation),
            r.birth_date && `Jahrgang ${r.birth_date.slice(0, 4)} (${Math.floor((Date.now() - new Date(r.birth_date)) / 31557600000)} J.)`,
            r.uci_rank && `UCI-Rang ${r.uci_rank}`,
            r.ranking_points && `${fmtPts(r.ranking_points)} Ranking-Punkte`].filter(Boolean).join(' · ')}</div>`}
        </div>
        <button class="ghost small" onClick=${() => setSlug(null)} aria-label="Schließen">✕</button>
      </div>
      ${error ? html`<p class="note err">${error}</p>` : !data ? html`<p class="muted">Lädt …</p>` : html`
        <div class="row between">
          ${years.length > 1 ? html`<div class="seg small">${years.map((yy) =>
            html`<button class=${yy === y ? 'active' : ''} onClick=${() => setYear(yy)}>${yy}</button>`)}</div>` : html`<span class="muted small">${y || ''}</span>`}
          <div><span class="big">${fmtPts(total)}</span> <span class="muted small">UCI-Punkte${y ? ` ${y}` : ''}</span></div>
        </div>
        <label class="check small"><input type="checkbox" checked=${allPlaces} onChange=${(e) => setAllPlaces(e.target.checked)} /> auch Platzierungen ohne Punkte</label>
        ${groups.length === 0 ? html`<p class="muted">Keine Ergebnisse${y ? ` in ${y}` : ''}.</p>`
          : html`<div class="modal-body">${groups.map((g) => html`<div class="detail-rider" key=${g.slug}>
              <div class="row between"><strong>${g.race?.name || g.slug}${g.race?.uci_class ? html` <span class="tag">${g.race.uci_class}</span>` : ''}</strong>
                <span>${g.sum ? fmtPts(g.sum) : ''}</span></div>
              <ul class="list compact">${g.rows.map((x) => html`<li class=${L ? 'clickable' : ''} onClick=${() => go(x)} title=${L ? 'Ganzes Ergebnis anzeigen' : ''}>
                <span>${describeEvent(x.ev.stage_name, x.ev.event_name)} <span class="muted">· ${x.rank_text && !/^\d+$/.test(x.rank_text) ? x.rank_text : `Platz ${x.rank}`}${x.result ? ` · ${x.result}` : ''}</span></span>
                <span class="muted">${fmtDate(x.ev.event_date)}${Number(x.uci_points) ? html` · <strong>${fmtPts(x.uci_points)}</strong>` : ''}${L ? ' ›' : ''}</span></li>`)}</ul>
            </div>`)}</div>`}`}
      <p class="muted small">Quelle: UCI DataRide. Antippen öffnet das ganze Ergebnis.</p>
    </div>
  </div>`;
}
