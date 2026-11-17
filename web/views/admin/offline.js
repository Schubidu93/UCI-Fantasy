// Admin → Offline-Draft: Kader samt Preisen eintragen (Auswahl oder CSV)
import { html, useState } from '../../vendor/preact-htm.js';
import { Msg, normName, rpc, useAction } from '../../lib.js';
import { pid, SPORT } from '../../sport/index.js';
import { RiderPicker } from '../picker.js';

export function OfflineImport({ c }) {
  const [rows, setRows] = useState([]);          // {manager_id, <Personen-Schlüssel>, price}
  const [unmatched, setUnmatched] = useState([]);
  const [errors, setErrors] = useState(null);
  const [mgr, setMgr] = useState(c.managers[0]?.id);
  const [price, setPrice] = useState('');
  const a = useAction();

  if (c.league.status !== 'setup') return html`<p class="card muted">Die Kader sind bereits fixiert.</p>`;

  const byName = {};
  c.people.forEach((r) => { byName[normName(r.name)] = r; });
  const taken = new Set(rows.map((r) => r.athlete_id));

  const parseCsv = (text) => {
    const out = [], miss = [];
    text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).forEach((line, i) => {
      const cols = line.split(/[;,\t]/).map((s) => s.trim().replace(/^"|"$/g, ''));
      if (i === 0 && /manager/i.test(cols[0])) return;      // Kopfzeile
      const [mName, rName, p] = cols;
      const m = c.managers.find((x) => normName(x.team_name) === normName(mName));
      const r = c.riderMap[rName] || byName[normName(rName)];
      if (!m || !r) miss.push(`Zeile ${i + 1}: ${!m ? `Manager „${mName}“` : ''}${!m && !r ? ' und ' : ''}${!r ? `${SPORT.one} „${rName}“` : ''} nicht gefunden`);
      else out.push({ manager_id: m.id, athlete_id: pid(r), price: p === undefined || p === '' ? null : +p });
    });
    setRows(out); setUnmatched(miss); setErrors(null);
  };

  const check = (commit) => a.run(async () => {
    const errs = await rpc('import_offline_draft', { p_league: c.league.id, p_rows: rows, p_commit: commit });
    setErrors(errs);
    if (commit && errs.length === 0) { c.reload(); location.hash = `#/league/${c.league.id}/team`; }
  });

  return html`<section class="card stack">
    <h3>Kader aus Offline-Draft eintragen</h3>
    <p class="muted small">CSV mit den Spalten <code>Manager;${SPORT.one};Preis</code> (Teamname, ${SPORT.csvNameHint}, Preis optional).
      Ohne Preis wird 0 gebucht. Geprüft wird: Kadergröße ${c.league.roster_size}, Summe ≤ 100, kein ${SPORT.one} doppelt, alle ${SPORT.many} ${SPORT.inPoolWord}.</p>
    <div class="row">
      <input type="file" accept=".csv,text/csv,text/plain" onChange=${(e) => e.target.files[0]?.text().then(parseCsv)} />
    </div>
    <details><summary>oder Text einfügen</summary>
      <textarea rows="6" placeholder=${`Manager;${SPORT.one};Preis`} onChange=${(e) => parseCsv(e.target.value)}></textarea></details>
    ${unmatched.length > 0 && html`<div class="note err">${unmatched.map((u) => html`<div>${u}</div>`)}</div>`}

    <h4>Einzeln hinzufügen</h4>
    <div class="row">
      <select value=${mgr} onChange=${(e) => setMgr(e.target.value)}>${c.managers.map((m) => html`<option value=${m.id}>${m.team_name}</option>`)}</select>
      <input type="number" min="0" max="100" placeholder="Preis" value=${price} onInput=${(e) => setPrice(e.target.value)} />
    </div>
    <${RiderPicker} people=${c.people.filter((r) => !taken.has(pid(r)))} limit=${8} action="Hinzufügen"
      onPick=${(r) => { setRows([...rows, { manager_id: mgr, athlete_id: pid(r), price: price === '' ? null : +price }]); setErrors(null); }} />

    <div class="grid2">${c.managers.map((m) => {
      const mine = rows.filter((r) => r.manager_id === m.id);
      return html`<div key=${m.id}><h4>${m.team_name} <span class="muted small">${mine.length}/${c.league.roster_size} · ${mine.reduce((s, r) => s + (r.price || 0), 0)} Pkt.</span></h4>
        <ul class="list compact">${mine.map((r) => html`<li>
          <span>${c.riderMap[r.athlete_id]?.name}</span>
          <span class="row"><span class="muted">${r.price ?? 0}</span>
            <button class="small ghost" onClick=${() => setRows(rows.filter((x) => x !== r))} aria-label="entfernen">✕</button></span></li>`)}</ul></div>`;
    })}</div>

    <div class="row">
      <button disabled=${a.busy || !rows.length} onClick=${() => check(false)}>Prüfen</button>
      <button class="primary" disabled=${a.busy || !errors || errors.length > 0}
        onClick=${() => confirm('Kader jetzt fixieren? Danach sind sie wie nach einem Live-Draft festgelegt.') && check(true)}>Kader fixieren</button>
    </div>
    ${errors && (errors.length ? html`<div class="note err">${errors.map((e) => html`<div>${e}</div>`)}</div>`
      : html`<p class="note ok">Alles in Ordnung – du kannst die Kader fixieren.</p>`)}
    <${Msg} msg=${a.msg} />
  </section>`;
}

