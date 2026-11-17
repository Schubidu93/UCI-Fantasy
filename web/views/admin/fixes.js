// Admin → Korrekturen: Punkte, Kader, Karriereende/Sperre
import { html, useState } from '../../vendor/preact-htm.js';
import { Msg, q, rpc, sb, useAction, useLoad } from '../../lib.js';
import { pid, SPORT } from '../../sport/index.js';
import { RiderPicker } from '../picker.js';

export function Fixes({ c }) {
  return html`<div class="stack">
    <${PointOverride} c=${c} />
    <${RosterFix} c=${c} />
    <${Inactive} c=${c} />
  </div>`;
}

function PointOverride({ c }) {
  const overrides = useLoad(() => q(sb.from('point_overrides').select('*').eq('league_id', c.league.id).order('created_at', { ascending: false })), [c.league.id]);
  const [md, setMd] = useState(c.matchdays.find((m) => m.status !== 'planned')?.id || '');
  const [mgr, setMgr] = useState(c.managers[0]?.id);
  const [rider, setRider] = useState('');
  const [points, setPoints] = useState('');
  const [reason, setReason] = useState('');
  const a = useAction();
  const people = [...new Set(c.roster.filter((r) => r.manager_id === mgr).map((r) => r.athlete_id))];
  const save = (val) => a.run(async () => {
    await rpc('admin_set_override', { p_league: c.league.id, p_matchday: md, p_manager: mgr, p_rider: rider,
      p_points: val === null ? null : +val, p_reason: reason });
    overrides.reload(); setPoints(''); setReason('');
  }, 'Korrektur gespeichert.');

  return html`<section class="card stack">
    <h3>Punkte korrigieren</h3>
    <p class="muted small">Setzt die Punkte eines ${SPORT.oneGen} in einem Spieltag fest (ersetzt den berechneten Wert, auch nach dem Einfrieren). Jede Korrektur wird protokolliert.</p>
    <div class="grid2 compact">
      <label>Spieltag<select value=${md} onChange=${(e) => setMd(e.target.value)}>${c.matchdays.map((m) => html`<option value=${m.id}>${m.name}</option>`)}</select></label>
      <label>Team<select value=${mgr} onChange=${(e) => { setMgr(e.target.value); setRider(''); }}>${c.managers.map((m) => html`<option value=${m.id}>${m.team_name}</option>`)}</select></label>
      <label>${SPORT.one}<select value=${rider} onChange=${(e) => setRider(e.target.value)}><option value="">– wählen –</option>
        ${people.map((s) => html`<option value=${s}>${c.riderMap[s]?.name || s}</option>`)}</select></label>
      <label>Punkte<input type="number" step="0.1" value=${points} onInput=${(e) => setPoints(e.target.value)} /></label>
      <label class="span2">Grund<input value=${reason} onInput=${(e) => setReason(e.target.value)} placeholder="z. B. Ergebnis aberkannt" /></label>
    </div>
    <div class="row"><button class="primary" disabled=${a.busy || !md || !rider || points === '' || !reason.trim()} onClick=${() => save(points)}>Speichern</button></div>
    <${Msg} msg=${a.msg} />
    ${overrides.data?.length > 0 && html`<ul class="list compact">${overrides.data.map((o) => html`<li key=${o.id}>
      <span>${c.matchdays.find((m) => m.id === o.matchday_id)?.name} · ${c.managerMap[o.manager_id]?.team_name} · ${c.riderMap[o.athlete_id]?.name}: <strong>${o.points}</strong>
        <span class="muted"> – ${o.reason}</span></span>
      <button class="small ghost" onClick=${() => a.run(async () => {
        await rpc('admin_set_override', { p_league: c.league.id, p_matchday: o.matchday_id, p_manager: o.manager_id, p_rider: o.athlete_id, p_points: null, p_reason: 'Korrektur aufgehoben' });
        overrides.reload(); })}>Aufheben</button></li>`)}</ul>`}
  </section>`;
}

function RosterFix({ c }) {
  const [mgr, setMgr] = useState(c.managers[0]?.id);
  const [drop, setDrop] = useState('');
  const [reason, setReason] = useState('');
  const a = useAction();
  const mine = c.active.filter((r) => r.manager_id === mgr);
  const run = (add) => a.run(async () => {
    await rpc('admin_roster_fix', { p_league: c.league.id, p_manager: mgr, p_add: add, p_drop: drop || null, p_price: 0, p_reason: reason });
    setDrop(''); c.reload();
  }, 'Kader geändert.');
  if (c.league.status !== 'active') return null;
  return html`<section class="card stack">
    <h3>Kader korrigieren</h3>
    <p class="muted small">Sofort wirksam (ab heute), ohne Waiver. Wird protokolliert.</p>
    <div class="grid2 compact">
      <label>Team<select value=${mgr} onChange=${(e) => { setMgr(e.target.value); setDrop(''); }}>${c.managers.map((m) => html`<option value=${m.id}>${m.team_name}</option>`)}</select></label>
      <label>Abgeben<select value=${drop} onChange=${(e) => setDrop(e.target.value)}><option value="">– niemand –</option>
        ${mine.map((r) => html`<option value=${r.athlete_id}>${c.riderMap[r.athlete_id]?.name}</option>`)}</select></label>
      <label class="span2">Grund<input value=${reason} onInput=${(e) => setReason(e.target.value)} /></label>
    </div>
    ${drop && html`<button disabled=${a.busy} onClick=${() => run(null)}>Nur abgeben</button>`}
    <${RiderPicker} people=${c.people.filter((r) => !c.owner[pid(r)])} limit=${8} action="Aufnehmen" onPick=${(r) => run(pid(r))} />
    <${Msg} msg=${a.msg} />
  </section>`;
}

function Inactive({ c }) {
  const a = useAction();
  const owned = c.active.map((r) => c.riderMap[r.athlete_id]).filter(Boolean);
  return html`<section class="card stack">
    <h3>Karriereende / Sperre</h3>
    <p class="muted small">Als inaktiv markierte ${SPORT.many} kann ihr Manager außer der Reihe sofort per Waiver ersetzen.</p>
    <ul class="list compact">${owned.filter((r) => r.inactive).map((r) => html`<li key=${pid(r)}><span>${r.name}</span>
      <button class="small" onClick=${() => a.run(async () => { await rpc('admin_mark_inactive', { p_league: c.league.id, p_rider: pid(r), p_inactive: false }); c.reload(); })}>Wieder aktiv</button></li>`)}</ul>
    <${RiderPicker} people=${owned.filter((r) => !r.inactive)} limit=${6} action="Inaktiv setzen"
      onPick=${(r) => a.run(async () => { await rpc('admin_mark_inactive', { p_league: c.league.id, p_rider: pid(r), p_inactive: true }); c.reload(); })} />
    <${Msg} msg=${a.msg} />
  </section>`;
}
