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
import { More } from './views/more.js';
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

// Navigation: fünf Bereiche (auf dem Handy als Leiste unten), darunter ggf. Unterreiter
const ICONS = {
  liga: '<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0V4zM17 5h3v2a3 3 0 0 1-3 3M7 5H4v2a3 3 0 0 0 3 3"/>',
  team: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
  draft: '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="18" r="1"/>',
  riders: '<circle cx="5.5" cy="17.5" r="3.5"/><circle cx="18.5" cy="17.5" r="3.5"/><circle cx="15" cy="5" r="1"/><path d="M12 17.5V14l-3-3 4-3 2 3h2"/>',
  races: '<path d="M4 22V4M4 4h13l-2 4 2 4H4"/>',
  more: '<path d="M3 6h18M3 12h18M3 18h18"/>',
};
const Icon = ({ name }) => html`<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" dangerouslySetInnerHTML=${{ __html: ICONS[name] }}></svg>`;

function sections(c) {
  const beforeDraft = ['setup', 'drafting'].includes(c.league.status);
  const afterDraft = ['active', 'finished'].includes(c.league.status);
  return [
    { key: 'liga', label: 'Liga', tabs: [['table', 'Tabelle'], ['results', 'Spieltage']] },
    beforeDraft
      ? { key: 'draft', label: 'Draft', tabs: [['draft', 'Draft']] }
      : { key: 'team', label: 'Team', tabs: [['team', 'Kader'], ...(afterDraft ? [['waiver', 'Waiver']] : [])] },
    { key: 'riders', label: 'Fahrer', tabs: [['riders', 'Fahrer']] },
    { key: 'races', label: 'Rennen', tabs: [['races', 'Rennen']] },
    { key: 'more', label: 'Mehr', tabs: [['more', 'Übersicht'], ['rules', 'Regeln'],
      ...(!beforeDraft ? [['draft', 'Draft']] : []), ...(c.isAdmin ? [['admin', 'Admin']] : [])] },
  ];
}

function LeagueShell({ id, tab, sub, sub2, session }) {
  const ctx = useLoad(() => loadLeague(id, session.user.id), [id, session.user.id]);
  if (!ctx.data) return html`<main class="wrap"><${Loading} error=${ctx.error} /></main>`;
  const c = { ...ctx.data, reload: ctx.reload, user: session.user };
  const defaultTab = c.league.status === 'setup' || c.league.status === 'drafting' ? 'draft' : 'table';
  const t = tab || defaultTab;
  const View = { draft: Draft, team: Team, riders: Riders, races: Races, rules: Rules, waiver: Waiver, results: Results,
    table: Table, admin: Admin, more: More }[t] || Table;
  const secs = sections(c);
  const current = secs.find((x) => x.tabs.some(([k]) => k === t)) || secs[0];
  const href = (k) => `#/league/${id}/${k}`;
  return html`
    <header class="league-head">
      <div class="wrap row between">
        <div class="league-title">
          <a href="#/" aria-label="Meine Ligen"><img src="logo.svg" alt="" class="head-logo" /></a>
          <div>
            <a href="#/" class="muted small-link">Meine Ligen</a>
            <h1>${c.league.name}</h1>
          </div>
        </div>
        <div class="muted small right">
          ${c.me ? html`<div><strong>${c.me.team_name}</strong></div>` : ''}
          <div title="Letzter Abruf der Ergebnisse von UCI DataRide">
            Stand vom ${fmtDateTime(c.sync?.last_run)}${c.sync && c.sync.ok === false ? ' ⚠︎' : ''}
          </div>
        </div>
      </div>
      <nav class="mainnav" aria-label="Bereiche">
        <div class="wrap mainnav-inner">
          ${secs.map((x) => html`<a href=${href(x.tabs[0][0])} class=${x === current ? 'active' : ''}>
            <${Icon} name=${x.key} /><span>${x.label}</span></a>`)}
        </div>
      </nav>
      ${current.tabs.length > 1 && html`<nav class="subnav wrap" aria-label="Unterbereiche">
        ${current.tabs.map(([k, label]) => html`<a href=${href(k)} class=${k === t ? 'active' : ''}>${label}</a>`)}
      </nav>`}
    </header>
    <main class="wrap"><${View} c=${c} sub=${sub} sub2=${sub2} /></main>`;
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
  if (parts[0] === 'league') return html`<${LeagueShell} key=${parts[1]} id=${parts[1]} tab=${parts[2]} sub=${parts[3]} sub2=${parts[4]} session=${session} />`;
  return html`<${Home} session=${session} />`;
}

registerServiceWorker();
render(html`<${App} /><${RiderModal} />`, document.getElementById('app'));
