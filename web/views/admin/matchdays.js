// Admin → Spieltage: anlegen, ändern, löschen und automatisch vorschlagen (Vorschläge je Sportart)
import { html, useState } from '../../vendor/preact-htm.js';
import { MatchdayProposals, EMPTY_HINT, NAME_PLACEHOLDER } from '../../sport/matchdays.js';
import { fmtDate, fmtUntil, Msg, rpc, today, useAction } from '../../lib.js';

export function Matchdays({ c }) {
  const empty = { id: null, name: '', starts_on: '', ends_on: '', deadline: '', waiver_deadline: '' };
  const two = c.league.transfer_mode === 'waiver_free';
  const [f, setF] = useState(empty);
  const [gen, setGen] = useState(null);
  const a = useAction();
  const locked = (m) => m.waivers_done || new Date(m.waiver_deadline || m.deadline) <= new Date();
  const toLocal = (ts) => { const d = new Date(ts); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };

  const save = (e) => {
    e.preventDefault();
    a.run(async () => {
      await rpc('upsert_matchday', { p_league: c.league.id, p_id: f.id, p_name: f.name, p_start: f.starts_on, p_end: f.ends_on,
        p_deadline: f.deadline ? new Date(f.deadline).toISOString() : null,
        p_waiver_deadline: two && f.waiver_deadline ? new Date(f.waiver_deadline).toISOString() : null });
      setF(empty); c.reload();
    }, 'Gespeichert.');
  };
  const createAll = () => a.run(async () => {
    const today = new Date().toISOString().slice(0, 10);
    for (const m of gen.filter((x) => x.starts_on > today)) {
      await rpc('upsert_matchday', { p_league: c.league.id, p_id: null, p_name: m.name, p_start: m.starts_on, p_end: m.ends_on });
    }
    setGen(null); c.reload();
  }, 'Spieltage angelegt.');

  return html`<section class="card stack">
    <h3>Spieltage</h3>
    <ul class="small muted md-help">
      <li>Zeiträume dürfen unterschiedlich lang sein, aber sich nicht überlappen. Lücken sind erlaubt (Punkte darin verfallen).</li>
      <li>${two
        ? 'Standard: Waiver bis eine Woche vor Start (Tagesende; ist der vorige Spieltag kürzer als 14 Tage: bis zu seiner Hälfte), danach freie Phase bis zum Vortag des Spieltags (Tagesende). Eigene Uhrzeiten sind möglich.'
        : 'Standard-Stichtag für Waiver und Aufstellung: Vortag des Spieltags um 20:00 Uhr.'}</li>
      <li>Leere Felder = Standard. Laufende und abgeschlossene Spieltage sind gesperrt.</li>
    </ul>
    ${c.matchdays.length ? html`<ul class="list md-admin">${c.matchdays.map((m, i) => html`<li key=${m.id}>
      <span class="md-no">${i + 1}</span>
      <span class="md-what"><strong>${m.name}</strong>
        <small>${fmtDate(m.starts_on)} – ${fmtDate(m.ends_on)}</small>
        ${two && html`<small>Waiver bis ${fmtUntil(m.waiver_deadline || m.deadline)}</small>`}
        <small>${two ? 'Freie Phase' : 'Waiver & Aufstellung'} bis ${fmtUntil(m.deadline)}</small></span>
      <span class="md-actions">
        <span class="tag">${m.frozen ? 'eingefroren' : m.status === 'closed' ? 'abgeschlossen' : m.status === 'running' ? 'läuft' : locked(m) ? 'Frist vorbei' : 'geplant'}</span>
        ${!locked(m) && html`
          <button class="small ghost" onClick=${() => setF({ ...m, deadline: toLocal(m.deadline), waiver_deadline: m.waiver_deadline ? toLocal(m.waiver_deadline) : '' })}>Bearbeiten</button>
          <button class="small danger" onClick=${() => confirm(`${m.name} löschen?`) && a.run(async () => { await rpc('delete_matchday', { p_id: m.id }); c.reload(); })}>Löschen</button>`}
      </span></li>`)}</ul>` : html`<p class="muted">${EMPTY_HINT}</p>`}

    <form class="grid2 compact" onSubmit=${save}>
      <label>Name<input required value=${f.name} onInput=${(e) => setF({ ...f, name: e.target.value })} placeholder=${NAME_PLACEHOLDER} /></label>
      <label>Start<input type="date" required value=${f.starts_on} onInput=${(e) => setF({ ...f, starts_on: e.target.value })} /></label>
      <label>Ende<input type="date" required value=${f.ends_on} onInput=${(e) => setF({ ...f, ends_on: e.target.value })} /></label>
      ${two && html`<label>Waiver-Auswertung (optional)<input type="datetime-local" value=${f.waiver_deadline} onInput=${(e) => setF({ ...f, waiver_deadline: e.target.value })} /></label>`}
      <label>Stichtag – Kader und Aufstellung fest (optional)<input type="datetime-local" value=${f.deadline} onInput=${(e) => setF({ ...f, deadline: e.target.value })} /></label>
      <div class="row"><button class="primary" disabled=${a.busy}>${f.id ? 'Änderung speichern' : 'Spieltag anlegen'}</button>
        ${f.id && html`<button type="button" class="ghost" onClick=${() => setF(empty)}>Abbrechen</button>`}</div>
    </form>

    <details><summary>Spieltage automatisch vorschlagen</summary>
      <${MatchdayProposals} c=${c} setGen=${setGen} a=${a} />
      ${gen && html`<p class="muted small">Vorschlag für ${fmtDate(c.league.season_start)} – ${fmtDate(c.league.season_end)}.
          Nach dem Anlegen einzeln anpassbar. Spieltage in der Vergangenheit werden übersprungen.</p>
        <ul class="list compact">${gen.map((m) => html`<li><span>${m.name}</span><span class="muted">${fmtDate(m.starts_on)} – ${fmtDate(m.ends_on)}</span></li>`)}</ul>
        <button class="primary" disabled=${a.busy || c.matchdays.length > 0} onClick=${createAll}>Alle anlegen</button>
        ${c.matchdays.length > 0 && html`<p class="muted small">Nur möglich, solange noch keine Spieltage angelegt sind.</p>`}`}
    </details>
    <${Msg} msg=${a.msg} />
  </section>`;
}

