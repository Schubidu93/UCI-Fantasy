// Fahrer-Fenster: Stammdaten und alle Ergebnisse mit UCI-Punkten eines Jahres
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { sb, q, fmtDate, fmtPts } from '../lib.js';
import { labelText } from './results.js';

export function RiderModal() {
  const [slug, setSlug] = useState(null);
  const [year, setYear] = useState(new Date().getFullYear());
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const open = (e) => { setSlug(e.detail); setData(null); setError(null); };
    const esc = (e) => { if (e.key === 'Escape') setSlug(null); };
    addEventListener('rider:open', open);
    addEventListener('keydown', esc);
    return () => { removeEventListener('rider:open', open); removeEventListener('keydown', esc); };
  }, []);

  useEffect(() => {
    if (!slug) return;
    let alive = true;
    (async () => {
      try {
        const [rider] = await q(sb.from('riders').select('*').eq('pcs_slug', slug));
        const results = await q(sb.from('results').select('race_slug,label,result_date,rank,uci_points')
          .eq('rider_slug', slug).gte('result_date', `${year}-01-01`).lte('result_date', `${year}-12-31`)
          .order('result_date', { ascending: false }).limit(1000));
        const slugs = [...new Set(results.map((r) => r.race_slug))];
        const races = slugs.length ? await q(sb.from('races').select('pcs_slug,name,uci_class').in('pcs_slug', slugs)) : [];
        if (alive) setData({ rider, results, races: Object.fromEntries(races.map((r) => [r.pcs_slug, r])) });
      } catch (e) {
        if (alive) setError(e.message);
      }
    })();
    return () => { alive = false; };
  }, [slug, year]);

  if (!slug) return null;
  const r = data?.rider;
  const total = (data?.results || []).reduce((s, x) => s + Number(x.uci_points), 0);
  // nach Rennen gruppieren, neuestes zuerst
  const groups = [];
  for (const x of data?.results || []) {
    let g = groups.find((g) => g.slug === x.race_slug);
    if (!g) groups.push(g = { slug: x.race_slug, race: data.races[x.race_slug], rows: [], sum: 0 });
    g.rows.push(x); g.sum += Number(x.uci_points);
  }

  return html`<div class="modal-back" onClick=${() => setSlug(null)}>
    <div class="modal card" role="dialog" aria-modal="true" aria-label="Fahrer" onClick=${(e) => e.stopPropagation()}>
      <div class="row between modal-head">
        <div>
          <h2>${r?.name || '…'}</h2>
          ${r && html`<div class="muted small">${[r.team, r.nation, r.uci_rank && `UCI-Rang ${r.uci_rank}`,
            r.ranking_points && `${fmtPts(r.ranking_points)} Ranking-Punkte`].filter(Boolean).join(' · ')}</div>`}
        </div>
        <button class="ghost small" onClick=${() => setSlug(null)} aria-label="Schließen">✕</button>
      </div>
      <div class="row between">
        <div class="seg small">${[year - 1, year, year + 1].filter((y) => y <= new Date().getFullYear()).map((y) =>
          html`<button class=${y === year ? 'active' : ''} onClick=${() => { setYear(y); setData(null); }}>${y}</button>`)}</div>
        <div><span class="big">${fmtPts(total)}</span> <span class="muted small">UCI-Punkte ${year}</span></div>
      </div>
      ${error ? html`<p class="note err">${error}</p>` : !data ? html`<p class="muted">Lädt …</p>`
        : groups.length === 0 ? html`<p class="muted">Keine Ergebnisse mit UCI-Punkten in ${year}.</p>`
        : html`<div class="modal-body">${groups.map((g) => html`<div class="detail-rider" key=${g.slug}>
            <div class="row between"><strong>${g.race?.name || g.slug}${g.race?.uci_class ? html` <span class="tag">${g.race.uci_class}</span>` : ''}</strong>
              <span>${fmtPts(g.sum)}</span></div>
            <ul class="list compact">${g.rows.map((x) => html`<li>
              <span>${labelText(x.label)}${x.rank ? html` <span class="muted">· Platz ${x.rank}</span>` : ''}</span>
              <span class="muted">${fmtDate(x.result_date)} · ${fmtPts(x.uci_points)}</span></li>`)}</ul>
          </div>`)}</div>`}
      <p class="muted small">Quelle: UCI-Weltrangliste (wöchentlich aktualisiert).</p>
    </div>
  </div>`;
}
