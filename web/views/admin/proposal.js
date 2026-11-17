// Hilfen für Spieltag-Vorschläge (beide Sportarten): Datumsrechnung und einfache Raster
export const iso = (d) => d.toISOString().slice(0, 10);
export const addDays = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return iso(d); };

export function proposal(kind, start, end) {
  const out = [];
  let s = start, i = 1;
  while (s <= end) {
    let e;
    if (kind === 'weekly') e = addDays(s, 6);
    else if (kind === 'biweekly') e = addDays(s, 13);
    else { const d = new Date(s + 'T00:00:00Z'); e = iso(new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0))); }
    if (e > end) e = end;
    out.push({ name: kind === 'weekly' ? `Woche ${i}` : kind === 'biweekly' ? `Spieltag ${i}`
      : new Date(s + 'T00:00:00Z').toLocaleDateString('de-DE', { month: 'long', year: 'numeric' }), starts_on: s, ends_on: e });
    s = addDays(e, 1); i++;
  }
  return out;
}
