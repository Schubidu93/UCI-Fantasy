// Einstieg: Anmeldung, Navigation, Liga-Rahmen
import { html, render, useState, useEffect } from './vendor/preact-htm.js';
import { sb, q, all, rpc, useLoad, Loading, fmtDateTime } from './lib.js';
import { Login } from './views/login.js';
import { Home, Join } from './views/home.js';
import { Draft } from './views/draft.js';
import { Team } from './views/team.js';
import { Waiver } from './views/waiver.js';
import { Results } from './views/results.js';
import { Table } from './views/table.js';
import { Admin } from './views/admin.js';
import { RiderModal } from './views/rider.js';
import { Riders } from './views/riders.js';
import { Races } from './views/races.js';
import { Rules } from './views/rules.js';
import { registerServiceWorker } from './views/push.js';

function useHash() {
  const [hash, setHash] = useState(location.hash.slice(1) || '/');
  useEffect(() => {
    const on = () => setHash(location.hash.slice(1) || '/');
    addEventListener('hashchange', on);
    return () => removeEventListener('hashchange', on);
  }, []);
  return hash;
}

function useSession() {
  const [session, setSession] = useState(undefined);
  useEffect(() => {
    sb.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = sb.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);
  return session;
}

// Alle Daten einer Liga, die mehrere Bereiche brauchen
async function loadLeague(id, userId) {
  rpc('process_due', { p_league: id }).catch(() => {});   // fällige Stichtage abarbeiten
  const league = (await q(sb.from('leagues').select('*').eq('id', id)))[0];
  if (!league) throw new Error('Liga nicht gefunden oder kein Zugriff.');
  const [managers, roster, matchdays, riders, sync] = await Promise.all([
    q(sb.from('managers').select('*').eq('league_id', id).order('draft_position', { nullsFirst: false }).order('joined_at')),
    all(() => sb.from('roster_entries').select('*').eq('league_id', id).order('id')),
    q(sb.from('matchdays').select('*').eq('league_id', id).order('starts_on')),
    all(() => sb.from('riders').select('*').eq('gender', league.gender).order('uci_rank', { nullsFirst: false }).order('pcs_slug')),
    q(sb.from('sync_status').select('*')),
  ]);
  const riderMap = Object.fromEntries(riders.map((r) => [r.pcs_slug, r]));
  const active = roster.filter((r) => !r.released_on);
  const owner = Object.fromEntries(active.map((r) => [r.rider_slug, r.manager_id]));
  const me = managers.find((m) => m.user_id === userId) || null;
  const managerMap = Object.fromEntries(managers.map((m) => [m.id, m]));
  const nextMatchday = matchdays.find((m) => new Date(m.deadline) > new Date()) || null;
  return {
    league, managers, managerMap, me, roster, active, owner, matchdays, nextMatchday,
    riders, riderMap, sync: sync[0] || null,
    isAdmin: league.admin_user === userId,
  };
}

const TABS = [
  ['draft', 'Draft'], ['team', 'Team'], ['riders', 'Fahrer'], ['races', 'Rennen'], ['waiver', 'Waiver'],
  ['results', 'Ergebnisse'], ['table', 'Tabelle'], ['rules', 'Regeln'], ['admin', 'Admin'],
];

function LeagueShell({ id, tab, sub, session }) {
  const ctx = useLoad(() => loadLeague(id, session.user.id), [id, session.user.id]);
  if (!ctx.data) return html`<main class="wrap"><${Loading} error=${ctx.error} /></main>`;
  const c = { ...ctx.data, reload: ctx.reload, user: session.user };
  const defaultTab = c.league.status === 'setup' || c.league.status === 'drafting' ? 'draft' : 'table';
  const t = tab || defaultTab;
  const View = { draft: Draft, team: Team, riders: Riders, races: Races, rules: Rules, waiver: Waiver, results: Results, table: Table, admin: Admin }[t] || Table;
  return html`
    <header class="league-head">
      <div class="wrap row between">
        <div>
          <a href="#/" class="muted small-link"><img src="logo.svg" alt="" class="mini-logo" /> Meine Ligen</a>
          <h1>${c.league.name}</h1>
        </div>
        <div class="muted small right">
          ${c.me ? html`<div><strong>${c.me.team_name}</strong></div>` : ''}
          <div title="Letzter Abruf der Ergebnisse von UCI DataRide">
            Stand vom ${fmtDateTime(c.sync?.last_run)}${c.sync && c.sync.ok === false ? ' ⚠︎' : ''}
          </div>
        </div>
      </div>
      <nav class="tabs wrap" aria-label="Bereiche">
        ${TABS.filter(([k]) => (k !== 'admin' || c.isAdmin) && (k !== 'waiver' || ['active', 'finished'].includes(c.league.status))).map(([k, label]) =>
          html`<a href=${`#/league/${id}/${k}`} class=${k === t ? 'active' : ''}>${label}</a>`)}
      </nav>
    </header>
    <main class="wrap"><${View} c=${c} sub=${sub} /></main>`;
}

function App() {
  const session = useSession();
  const hash = useHash();
  if (session === undefined) return html`<main class="wrap"><p class="muted">Lädt …</p></main>`;
  const parts = hash.split('/').filter(Boolean);
  if (!session) {
    if (parts[0] === 'join') sessionStorage.setItem('joinAfterLogin', parts[1]);
    return html`<${Login} />`;
  }
  const pending = sessionStorage.getItem('joinAfterLogin');
  if (pending) {
    sessionStorage.removeItem('joinAfterLogin');
    location.hash = `#/join/${pending}`;
  }
  if (parts[0] === 'join') return html`<${Join} code=${parts[1]} session=${session} />`;
  if (parts[0] === 'league') return html`<${LeagueShell} key=${parts[1]} id=${parts[1]} tab=${parts[2]} sub=${parts[3]} session=${session} />`;
  return html`<${Home} session=${session} />`;
}

registerServiceWorker();
render(html`<${App} /><${RiderModal} />`, document.getElementById('app'));
