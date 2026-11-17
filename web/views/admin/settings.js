// Admin → Einstellungen: Liga-Einstellungen, neue Saison, Liga löschen
import { html, useState } from '../../vendor/preact-htm.js';
import { rpc, useAction, Msg } from '../../lib.js';
import { LeagueSettingsFields } from '../home.js';
import { SPORT } from '../../sport/index.js';
import { SEASON_END, settingsInit, settingsPayload } from '../../sport/settings.js';
import { SettingsExtra } from '../../sport/admin.js';

export function Settings({ c }) {
  const l = c.league;
  const locked = l.status !== 'setup';
  const [f, setF] = useState(settingsInit(l));
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const a = useAction();
  const save = (e) => {
    e.preventDefault();
    const s = { name: f.name, scoring_mode: f.scoring_mode, waiver_mode: f.waiver_mode, transfer_mode: f.transfer_mode, season_end: f.season_end,
      ...settingsPayload(f, { locked }) };
    if (!locked) Object.assign(s, {
      max_managers: +f.max_managers, roster_size: +f.roster_size,
      draft_mode: f.draft_mode, draft_order: f.draft_order, bid_seconds: +f.bid_seconds, gender: f.gender, season_start: f.season_start,
    });
    a.run(async () => { await rpc('update_league_settings', { p_league: l.id, p_settings: s }); c.reload(); }, 'Gespeichert.');
  };
  return html`<section class="card">
    <form class="stack" onSubmit=${save}>
      <label>Name der Liga<input value=${f.name} onInput=${set('name')} /></label>
      <${LeagueSettingsFields} f=${f} set=${set} locked=${locked} />
      ${locked && html`<p class="muted small">Nach dem Draft sind nur noch Wertungsmodus (gilt ab dem nächsten Stichtag), Transfers, Waiver-Modus und Saisonende änderbar.
        Beim Wechsel der Transfers werden die Standardfristen künftiger Spieltage neu gesetzt.</p>`}
      <div class="row"><button class="primary" disabled=${a.busy}>Speichern</button></div>
      <${Msg} msg=${a.msg} />
    </form>
    <${SettingsExtra} c=${c} />
    <${NewSeason} c=${c} />
    <${DeleteLeague} c=${c} />
  </section>`;
}


function NewSeason({ c }) {
  const y = +c.league.season_end.slice(0, 4) + 1;
  const [f, setF] = useState({ name: c.league.name.replace(/\b20\d\d\b/, '').trim() + ` ${y}`, start: `${y}-01-01`, end: `${y}-${SEASON_END}`, keepers: 0, surcharge: 5 });
  const a = useAction();
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  return html`<details class="season-zone"><summary>Neue Saison anlegen</summary>
    <p class="small muted">Legt eine neue Liga mit denselben Mitspielern und Einstellungen an. Alle sind sofort Mitglied.
      Mit Keepern darf jeder Manager ${SPORT.many} aus seinem jetzigen Kader behalten – zum diesjährigen Preis plus Aufschlag.</p>
    <div class="grid2 compact">
      <label>Name<input value=${f.name} onInput=${set('name')} /></label>
      <label>Saisonstart<input type="date" value=${f.start} onInput=${set('start')} /></label>
      <label>Saisonende<input type="date" value=${f.end} onInput=${set('end')} /></label>
      <label>Keeper pro Manager (0–10)<input type="number" min="0" max="10" value=${f.keepers} onInput=${set('keepers')} /></label>
      ${+f.keepers > 0 && html`<label>Aufschlag auf den Preis<input type="number" min="0" max="50" value=${f.surcharge} onInput=${set('surcharge')} /></label>`}
    </div>
    <div class="row"><button class="primary" disabled=${a.busy}
      onClick=${() => a.run(async () => {
        const id = await rpc('copy_league', { p_league: c.league.id, p_name: f.name, p_season_start: f.start, p_season_end: f.end,
          p_keeper_count: +f.keepers, p_keeper_surcharge: +f.surcharge });
        location.hash = `#/league/${id}/admin`;
      })}>Neue Saison anlegen</button></div>
    <${Msg} msg=${a.msg} /></details>`;
}

function DeleteLeague({ c }) {
  const [confirm, setConfirm] = useState('');
  const a = useAction();
  return html`<details class="danger-zone"><summary>Liga löschen</summary>
    <p class="small">Löscht die Liga mit allen Kadern und Punkten unwiderruflich. Zum Bestätigen den Liganamen eingeben.</p>
    <div class="row"><input value=${confirm} onInput=${(e) => setConfirm(e.target.value)} placeholder=${c.league.name} />
      <button class="danger" disabled=${confirm !== c.league.name || a.busy}
        onClick=${() => a.run(async () => { await rpc('delete_league', { p_league: c.league.id }); location.hash = '#/'; })}>Endgültig löschen</button></div>
    <${Msg} msg=${a.msg} /></details>`;
}
