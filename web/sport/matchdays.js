// Spieltag-Vorschläge im Radsport: die drei großen Rundfahrten (aus dem UCI-Kalender) sind je ein eigener Spieltag,
// dazwischen Rennblöcke; kein WorldTour-Rennen wird geteilt.
import { html } from '../vendor/preact-htm.js';
import { addDays, proposal } from '../views/admin/proposal.js';
import { all, sb } from '../lib.js';

export const EMPTY_HINT = 'Noch keine Spieltage. Am schnellsten: unten „Spieltage automatisch vorschlagen“ → „Aus Rennkalender“ → „Alle anlegen“.';
export const NAME_PLACEHOLDER = 'z. B. Tour de France';

// Rennblöcke aus dem echten Kalender (inkl. vorläufiger Termine): die drei großen Rundfahrten sind je ein
// eigener Spieltag, dazwischen Blöcke. Grenzen werden so verschoben, dass kein WorldTour-Rennen geteilt wird.
const GT = [['Giro', /giro d.italia/i, 'Vor dem Giro'], ['Tour', /tour de france/i, 'Vor der Tour'],
  ['Vuelta', /vuelta.*espa[ñn]a/i, 'Vor der Vuelta']];
async function calendarProposal(league) {
  const races = await all(() => sb.from('races').select('name,uci_class,start_date,end_date')
    .eq('gender', league.gender).lte('start_date', league.season_end).gte('end_date', league.season_start)
    .not('start_date', 'is', null).order('start_date'));
  const wt = races.filter((r) => /^[12]\.(UWT|WWT)$/.test(r.uci_class || '')).map((r) => ({ ...r, end_date: r.end_date || r.start_date }));
  const tours = GT.map(([short, re, gap]) => {
    const r = wt.find((x) => x.uci_class.startsWith('2.') && re.test(x.name));
    return r && { short, gap, name: r.name, starts_on: r.start_date, ends_on: r.end_date };
  }).filter(Boolean).sort((x, y) => (x.starts_on > y.starts_on ? 1 : -1))
    .filter((t, i, arr) => !arr.slice(0, i).some((x) => x.ends_on >= t.starts_on));
  if (!tours.length) return null;
  // Grenze (erster Tag eines Blocks) nicht mitten in ein WorldTour-Rennen legen: auf Start oder Tag nach Ende schieben
  const cut = (d, lo, hi) => {
    const r = wt.find((x) => x.start_date < d && x.end_date >= d);
    if (!r) return d;
    const a = r.start_date, b = addDays(r.end_date, 1);
    const ok = (x) => x > lo && x <= hi;
    const da = Math.abs(new Date(d) - new Date(a)), db = Math.abs(new Date(b) - new Date(d));
    return (da <= db ? [a, b] : [b, a]).find(ok) || d;
  };
  const out = [];
  const block = (from, to, name) => { if (from <= to) out.push({ name, starts_on: from, ends_on: to }); };
  let cursor = league.season_start;
  tours.forEach((t, i) => {
    const before = addDays(t.starts_on, -1);
    if (i === 0) {
      const march = cut(`${t.starts_on.slice(0, 4)}-03-01`, cursor, before);
      if (march > addDays(cursor, 13) && addDays(march, 13) <= before) {
        block(cursor, addDays(march, -1), 'Saisonstart'); block(march, before, 'Frühjahrsklassiker');
      } else block(cursor, before, 'Saisonstart');
    } else block(cursor, before, t.gap);
    block(t.starts_on < league.season_start ? league.season_start : t.starts_on,
      t.ends_on > league.season_end ? league.season_end : t.ends_on, t.name);
    cursor = addDays(t.ends_on, 1);
  });
  block(cursor, league.season_end, 'Herbst');
  return out;
}

/** Knöpfe für „Spieltage automatisch vorschlagen“ (Admin → Spieltage) */
export function MatchdayProposals({ c, setGen, a }) {
  return html`<div class="row">
        <button class="primary" onClick=${() => a.run(async () => {
          const p = await calendarProposal(c.league);
          if (!p) throw new Error('Für diese Saison sind noch keine großen Rundfahrten im Kalender – nimm vorerst „Monatlich“.');
          setGen(p);
        })}>Aus Rennkalender</button>
        <button onClick=${() => setGen(proposal('monthly', c.league.season_start, c.league.season_end))}>Monatlich</button>
        <button onClick=${() => setGen(proposal('weekly', c.league.season_start, c.league.season_end))}>Wöchentlich</button>
      </div>`;
}
