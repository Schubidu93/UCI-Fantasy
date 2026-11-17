// Aufstellung für den nächsten Spieltag (Team → Kader): Radsport mit fester Zahl wertender Fahrer
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { fmtDeadline } from '../views/deadline.js';
import { Msg, rpc, useAction } from '../lib.js';
import { RiderCell } from './index.js';

export function Lineup({ c }) {
  const md = c.nextMatchday;
  const size = c.league.lineup_size;
  const mine = c.active.filter((r) => r.manager_id === c.me.id);
  const [sel, setSel] = useState(null);
  const a = useAction();
  useEffect(() => {
    if (!md) return;
    rpc('effective_lineup', { p_matchday: md.id, p_manager: c.me.id })
      .then((rows) => setSel(new Set(rows.map((r) => (typeof r === 'string' ? r : r.effective_lineup)))))
      .catch(() => setSel(new Set()));
  }, [md?.id]);
  if (!md) return html`<section class="card"><h3>Aufstellung</h3><p class="muted">Kein kommender Spieltag angelegt.${c.isAdmin ? html` <a href=${`#/league/${c.league.id}/admin`}>Spieltag anlegen →</a>` : ''}</p></section>`;
  if (!sel) return null;
  const toggle = (slug) => { const s = new Set(sel); s.has(slug) ? s.delete(slug) : s.add(slug); setSel(s); };
  return html`<section class="card">
    <h3>Aufstellung für ${md.name}</h3>
    <p class="muted small">${size} von ${c.league.roster_size} Fahrern werten. Änderbar bis <strong>${fmtDeadline(md.deadline)}</strong>,
      danach ist sie für ${md.name} fest. Ohne neue Eingabe gilt die letzte Aufstellung.</p>
    <ul class="list compact">${mine.map((r) => html`<li key=${r.id}>
      <label class="check"><input type="checkbox" checked=${sel.has(r.athlete_id)} onChange=${() => toggle(r.athlete_id)} />
        <${RiderCell} r=${c.riderMap[r.athlete_id]} /></label></li>`)}</ul>
    <div class="row">
      <button class="primary" disabled=${a.busy || sel.size !== size}
        onClick=${() => a.run(() => rpc('set_lineup', { p_matchday: md.id, p_riders: [...sel] }), 'Aufstellung gespeichert.')}>
        Speichern (${sel.size}/${size})</button>
    </div>
    <${Msg} msg=${a.msg} />
  </section>`;
}
