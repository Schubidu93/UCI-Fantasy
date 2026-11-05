import { html, useState } from '../vendor/preact-htm.js';
import { sb, q, rpc, useLoad, useAction, Msg, Loading, fmtDate, fmtDateTime } from '../lib.js';
import { PushToggle } from './push.js';

// Echter Stand der Liga: Draft geplant/läuft/abgeschlossen, Saison läuft mit aktuellem Spieltag, beendet
function leagueStatus(l, mds) {
  const today = new Date().toISOString().slice(0, 10);
  if (l.status === 'setup') return [l.draft_at ? `Draft am ${fmtDateTime(l.draft_at)}` : 'Draft steht bevor', ''];
  if (l.status === 'drafting') return ['Draft läuft', 'ok'];
  if (l.status === 'finished' || today > l.season_end) return ['Saison beendet', ''];
  if (today < l.season_start) return [`Draft abgeschlossen · Saisonstart ${fmtDate(l.season_start)}`, ''];
  const now = mds.find((m) => m.starts_on <= today && m.ends_on >= today);
  if (now) return [`Saison läuft · ${now.name}`, 'ok'];
  const next = mds.find((m) => m.starts_on > today);
  return [next ? `Saison läuft · nächster Spieltag ${next.name} ab ${fmtDate(next.starts_on)}` : 'Saison läuft', 'ok'];
}

export function Home({ session }) {
  const leagues = useLoad(() => q(sb.from('managers')
    .select('team_name, leagues(id, name, status, season_start, season_end, gender, draft_at, admin_user)')
    .eq('user_id', session.user.id)), [session.user.id]);
  const ids = (leagues.data || []).map((m) => m.leagues?.id).filter(Boolean);
  const mds = useLoad(() => (ids.length ? q(sb.from('matchdays').select('league_id,name,starts_on,ends_on').in('league_id', ids).order('starts_on'))
    : Promise.resolve([])), [ids.join()]);
  const [creating, setCreating] = useState(false);
  const [code, setCode] = useState('');

  return html`<main class="wrap stack home">
    <div class="row between">
      <div class="brand"><img src="logo.svg" alt="" class="logo-img" /> UCI Fantasy</div>
      <button class="ghost" onClick=${() => sb.auth.signOut()}>Abmelden</button>
    </div>
    <h2>Meine Ligen</h2>
    ${!leagues.data ? html`<${Loading} error=${leagues.error} />` : leagues.data.length === 0
      ? html`<p class="muted">Du bist noch in keiner Liga. Lege eine an oder tritt mit einem Einladungscode bei.</p>`
      : html`<ul class="cards">${leagues.data.filter((m) => m.leagues).map((m) => html`<li key=${m.leagues.id}>
          <a class="card link" href=${`#/league/${m.leagues.id}`}>
            <span class="row between"><strong>${m.leagues.name}</strong>
              ${m.leagues.admin_user === session.user.id && html`<span class="tag admin-tag" title="Du verwaltest diese Liga">⚙️ Admin</span>`}</span>
            <span class="muted">${m.team_name} · ${m.leagues.gender === 'women' ? 'Frauen' : 'Männer'}</span>
            ${(([text, cls]) => html`<span class=${`tag ${cls}`}>${text}</span>`)(leagueStatus(m.leagues, (mds.data || []).filter((x) => x.league_id === m.leagues.id)))}
            <span class="muted small">${fmtDate(m.leagues.season_start)} – ${fmtDate(m.leagues.season_end)}</span>
          </a></li>`)}</ul>`}

    <${PushToggle} />
    <div class="grid2">
      <div class="card">
        <h3>Liga beitreten</h3>
        <form class="row" onSubmit=${(e) => { e.preventDefault(); if (code.trim()) location.hash = `#/join/${code.trim()}`; }}>
          <input placeholder="Einladungscode" value=${code} onInput=${(e) => setCode(e.target.value)} />
          <button>Weiter</button>
        </form>
      </div>
      <div class="card">
        <h3>Neue Liga</h3>
        ${creating ? html`<${CreateLeague} onCancel=${() => setCreating(false)} />`
          : html`<button class="primary" onClick=${() => setCreating(true)}>Liga anlegen</button>`}
      </div>
    </div>
  </main>`;
}

function CreateLeague({ onCancel }) {
  const y = new Date().getMonth() >= 9 ? new Date().getFullYear() + 1 : new Date().getFullYear();
  const [f, setF] = useState({
    name: '', team_name: '', max_managers: 8, roster_size: 15, scoring_mode: 'full', lineup_size: 9,
    max_per_team: '', draft_mode: 'live', draft_order: 'ranking', bid_seconds: 15, waiver_mode: 'priority', transfer_mode: 'waiver_free',
    gender: 'men', season_start: `${y}-01-01`, season_end: `${y}-10-31`,
  });
  const a = useAction();
  // Beim Wechsel auf Snake-Draft eine sinnvolle Pick-Zeit vorschlagen
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value,
    ...(k === 'draft_mode' && e.target.value === 'snake' && +f.bid_seconds === 15 ? { bid_seconds: 60 } : {}) });

  const submit = (e) => {
    e.preventDefault();
    a.run(async () => {
      const s = {
        max_managers: +f.max_managers, roster_size: +f.roster_size, scoring_mode: f.scoring_mode,
        lineup_size: f.scoring_mode === 'lineup' ? +f.lineup_size : null,
        max_per_team: f.max_per_team ? +f.max_per_team : null, draft_mode: f.draft_mode, draft_order: f.draft_order,
        bid_seconds: +f.bid_seconds, waiver_mode: f.waiver_mode, transfer_mode: f.transfer_mode, gender: f.gender,
        season_start: f.season_start, season_end: f.season_end,
      };
      const id = await rpc('create_league', { p_name: f.name, p_team_name: f.team_name, p_settings: s });
      location.hash = `#/league/${id}/admin`;
    });
  };

  return html`<form class="stack" onSubmit=${submit}>
    <label>Name der Liga<input required value=${f.name} onInput=${set('name')} /></label>
    <label>Dein Teamname<input required value=${f.team_name} onInput=${set('team_name')} /></label>
    <${LeagueSettingsFields} f=${f} set=${set} locked=${false} />
    <div class="row">
      <button class="primary" disabled=${a.busy}>Anlegen</button>
      <button type="button" class="ghost" onClick=${onCancel}>Abbrechen</button>
    </div>
    <${Msg} msg=${a.msg} />
  </form>`;
}

// Gemeinsame Felder für "Liga anlegen" und Admin-Einstellungen.
// locked = nach dem Draft: nur noch Wertungsmodus, Waiver-Modus, Saisonende änderbar.
export function LeagueSettingsFields({ f, set, locked }) {
  return html`<fieldset class="grid2 compact">
    <label>Wertung
      <select value=${f.gender} onChange=${set('gender')} disabled=${locked}>
        <option value="men">Männer Elite</option><option value="women">Frauen Elite</option>
      </select></label>
    <label>Anzahl Mitspieler (2–20)<input type="number" min="2" max="20" value=${f.max_managers} onInput=${set('max_managers')} disabled=${locked} /></label>
    <label>Fahrer pro Team (5–30)<input type="number" min="5" max="30" value=${f.roster_size} onInput=${set('roster_size')} disabled=${locked} /></label>
    <label>Max. Fahrer pro Profiteam<input type="number" min="1" placeholder="keine Grenze" value=${f.max_per_team ?? ''} onInput=${set('max_per_team')} disabled=${locked} /></label>
    <label>Wertungsmodus
      <select value=${f.scoring_mode} onChange=${set('scoring_mode')}>
        <option value="full">Gesamtkader zählt</option><option value="lineup">Aufstellung pro Spieltag</option>
      </select></label>
    ${f.scoring_mode === 'lineup' && html`<label>Wertende Fahrer<input type="number" min="1" max=${f.roster_size} value=${f.lineup_size ?? ''} onInput=${set('lineup_size')} /></label>`}
    <label>Draft-Modus
      <select value=${f.draft_mode} onChange=${set('draft_mode')} disabled=${locked}>
        <option value="live">Live-Auktion</option><option value="snake">Snake-Draft</option><option value="offline">Offline-Import</option>
      </select></label>
    ${f.draft_mode === 'snake' && html`
      <label>Sekunden pro Pick<input type="number" min="5" max="600" value=${f.bid_seconds} onInput=${set('bid_seconds')} disabled=${locked} /></label>`}
    ${f.draft_mode === 'live' && html`
      <label>Reihenfolge
        <select value=${f.draft_order} onChange=${set('draft_order')} disabled=${locked}>
          <option value="ranking">nach UCI-Rangliste</option><option value="nominate">reihum nominieren</option>
        </select></label>
      <label>Sekunden pro Gebot<input type="number" min="5" max="120" value=${f.bid_seconds} onInput=${set('bid_seconds')} disabled=${locked} /></label>`}
    <label>Transfers
      <select value=${f.transfer_mode || 'waiver_free'} onChange=${set('transfer_mode')}>
        <option value="waiver_free">Waiver-Runde + freie Phase</option><option value="waiver">Nur Waiver (bis zum Stichtag)</option>
      </select></label>
    <label>Waiver-Modus
      <select value=${f.waiver_mode} onChange=${set('waiver_mode')}>
        <option value="priority">Priorität (Tabellenletzter zuerst)</option><option value="faab">FAAB (Bieten mit Restbudget)</option>
      </select></label>
    <label>Saisonstart<input type="date" value=${f.season_start} onInput=${set('season_start')} disabled=${locked} /></label>
    <label>Saisonende<input type="date" value=${f.season_end} onInput=${set('season_end')} /></label>
  </fieldset>
  <p class="muted small">${f.draft_mode === 'snake' ? 'Im Snake-Draft kosten Fahrer nichts; das Budget von 100 bleibt für FAAB-Waiver.' : 'Budget 100 pro Manager, Mindestgebot 1 (fest).'}</p>`;
}

export function Join({ code, session }) {
  const info = useLoad(() => rpc('league_by_code', { p_code: code }), [code]);
  const [team, setTeam] = useState('');
  const a = useAction();
  const join = (claim) => a.run(async () => {
    const id = await rpc('join_league', { p_code: code, p_team_name: team, p_claim: claim || null });
    location.hash = `#/league/${id}`;
  });

  if (!info.data) return html`<main class="wrap narrow">${info.data === null && !info.loading
    ? html`<p class="note err">Einladungslink ungültig.</p>` : html`<${Loading} error=${info.error} />`}</main>`;
  const l = info.data;
  if (l.already_member) { location.hash = `#/league/${l.id}`; return null; }
  return html`<main class="wrap narrow">
    <div class="card stack">
      <h2>${l.name}</h2>
      <p class="muted">${l.members} von ${l.max_managers} Plätzen belegt</p>
      <label>Dein Teamname<input value=${team} onInput=${(e) => setTeam(e.target.value)} /></label>
      ${l.status === 'setup' && html`<button class="primary" disabled=${a.busy || !team.trim()} onClick=${() => join(null)}>Beitreten</button>`}
      ${l.placeholders.length > 0 && html`<div>
        <p>Oder einen vorbereiteten Platz übernehmen:</p>
        <ul class="list">${l.placeholders.map((p) => html`<li key=${p.id}>${p.team_name}
          <button class="small" disabled=${a.busy} onClick=${() => join(p.id)}>Übernehmen</button></li>`)}</ul>
      </div>`}
      <${Msg} msg=${a.msg} />
    </div>
  </main>`;
}
