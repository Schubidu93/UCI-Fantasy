import { html, useState, useMemo } from '../vendor/preact-htm.js';
import { sb, q, rpc, useLoad, useAction, Msg, RiderCell, normName, withFlag, teamName } from '../lib.js';
import { NextDeadline, transferPhase, fmtDeadline } from './deadline.js';

const STATUS = { pending: 'offen', won: 'Zuschlag', lost: 'kein Zuschlag', cancelled: 'zurückgezogen' };

export function Waiver({ c }) {
  const L = c.league.id;
  const order = useLoad(() => rpc('waiver_order', { p_league: L }), [L]);
  const claims = useLoad(() => q(sb.from('waiver_claims').select('*').eq('league_id', L).order('created_at', { ascending: false }).limit(200)), [L]);
  const [pick, setPick] = useState(null);
  const a = useAction();

  if (c.league.status !== 'active') return html`<p class="muted card">Waiver sind nach dem Draft möglich.</p>`;
  if (!c.me) return html`<p class="muted card">Nur für Manager dieser Liga.</p>`;

  const reload = () => { claims.reload(); c.reload(); };
  const mine = (claims.data || []).filter((x) => x.manager_id === c.me.id);
  const pending = mine.filter((x) => x.status === 'pending').sort((x, y) => x.priority - y.priority);
  const done = (claims.data || []).filter((x) => x.status !== 'pending');
  const myPos = order.data?.find((o) => o.manager_id === c.me.id)?.waiver_pos;
  const name = (s) => c.riderMap[s]?.name || s;

  const move = (i, dir) => {
    const ids = pending.map((p) => p.id);
    [ids[i], ids[i + dir]] = [ids[i + dir], ids[i]];
    a.run(async () => { await rpc('reorder_waivers', { p_league: L, p_ids: ids }); claims.reload(); });
  };

  return html`<div class="stack">
    <${NextDeadline} c=${c} />
    <section class="card">
      <div class="row between">
        <div><h2>Waiver</h2>
          </div>
        <div class="right">
          <div class="big">${myPos ?? '–'}<span class="muted small"> / ${c.managers.length}</span></div>
          <div class="muted small">deine Waiver-Position</div>
        </div>
      </div>
      <p class="muted small">${c.league.waiver_mode === 'faab'
        ? `FAAB: verdecktes Gebot mit deinem Restbudget (${c.me.budget_left}). Höchstgebot gewinnt, bei Gleichstand der schlechter Platzierte.`
        : 'Priorität: Der Tabellenletzte wählt zuerst. Pro Runde bekommt jeder höchstens einen Fahrer.'}</p>
      ${order.data && html`<details><summary>Reihenfolge aller Manager</summary>
        <ol>${order.data.map((o) => html`<li key=${o.manager_id}>${o.team_name}</li>`)}</ol></details>`}
    </section>

    ${pending.length > 0 && html`<section class="card">
      <h3>Meine Anträge (Wunschreihenfolge)</h3>
      <ol class="list">${pending.map((p, i) => html`<li key=${p.id}>
        <span><strong>+ ${name(p.add_rider)}</strong>${p.drop_rider ? html` <span class="muted">für</span> − ${name(p.drop_rider)}` : html` <span class="muted">(freier Platz)</span>`}
          ${c.league.waiver_mode === 'faab' ? html` <span class="tag">${p.bid}</span>` : ''}</span>
        <span class="row">
          <button class="small ghost" disabled=${i === 0} onClick=${() => move(i, -1)} aria-label="nach oben">↑</button>
          <button class="small ghost" disabled=${i === pending.length - 1} onClick=${() => move(i, 1)} aria-label="nach unten">↓</button>
          <button class="small" onClick=${() => a.run(async () => { await rpc('cancel_waiver', { p_id: p.id }); claims.reload(); })}>Löschen</button>
        </span></li>`)}</ol>
    </section>`}

    ${pick ? html`<${ClaimForm} c=${c} add=${pick} onDone=${() => { setPick(null); reload(); }} onCancel=${() => setPick(null)} />`
      : html`<${FreeAgents} c=${c} onPick=${setPick} free=${transferPhase(c).phase === 'free'} />`}
    <${Msg} msg=${a.msg} />

    ${done.length > 0 && html`<section class="card">
      <h3>Abgewickelte Anträge</h3>
      <ul class="list compact">${done.slice(0, 40).map((p) => html`<li key=${p.id}>
        <span>${c.managerMap[p.manager_id]?.team_name}: + ${name(p.add_rider)}${p.drop_rider ? ` / − ${name(p.drop_rider)}` : ''}</span>
        <span class=${p.status === 'won' ? 'tag ok' : 'tag'}>${STATUS[p.status]}${p.note ? ` – ${p.note}` : ''}</span></li>`)}</ul>
    </section>`}
  </div>`;
}

function FreeAgents({ c, onPick, free: freePhase }) {
  const [term, setTerm] = useState('');
  const [team, setTeam] = useState('');
  const [nation, setNation] = useState('');
  const lockedSince = c.league.last_waiver_run;
  const locked = useMemo(() => new Set(freePhase ? [] : c.roster.filter((r) => r.released_at && lockedSince && r.released_at >= lockedSince).map((r) => r.rider_slug)), [c.roster, freePhase]);
  const free = c.riders.filter((r) => !c.owner[r.pcs_slug]);
  const teams = [...new Set(free.map((r) => r.team).filter(Boolean))].sort();
  const nations = [...new Set(free.map((r) => r.nation).filter(Boolean))].sort();
  const t = normName(term);
  const list = free.filter((r) => (!team || normName(team).split(' ').every((w) => normName(r.team || '').includes(w))) && (!nation || r.nation === nation)
    && (!t || t.split(' ').every((w) => normName(r.name).includes(w)))).slice(0, 100);

  return html`<section class="card">
    <h3>Freie Fahrer</h3>
    <div class="filters">
      <input type="search" placeholder="Name" value=${term} onInput=${(e) => setTerm(e.target.value)} />
      <input type="search" list=${`teams-waiver`} placeholder="Team (z. B. UAE)" value=${team} onInput=${(e) => setTeam(e.target.value)} />
      <datalist id=${`teams-waiver`}>${teams.map((x) => html`<option value=${teamName(x)} />`)}</datalist>
      <select value=${nation} onChange=${(e) => setNation(e.target.value)}><option value="">Alle Nationen</option>${nations.map((x) => html`<option value=${x}>${withFlag(x)}</option>`)}</select>
    </div>
    <ul class="list">${list.map((r) => html`<li key=${r.pcs_slug}>
      <${RiderCell} r=${r} />
      ${locked.has(r.pcs_slug)
        ? html`<span class="tag" title="Abgegebene Fahrer sind bis zum nächsten Stichtag gesperrt – Antrag ist trotzdem möglich">gesperrt</span>` : ''}
      <button class=${freePhase ? 'small primary' : 'small'} onClick=${() => onPick(r)}>${freePhase ? 'Holen' : 'Antrag'}</button></li>`)}</ul>
    <p class="muted small">Sortiert nach UCI-Rang, max. 100 Treffer.</p>
  </section>`;
}

function ClaimForm({ c, add, onDone, onCancel }) {
  const mine = c.active.filter((r) => r.manager_id === c.me.id);
  const open = c.league.roster_size - mine.length;            // freie Kaderplätze (z. B. nach ungleichem Tausch)
  const [drop, setDrop] = useState(open > 0 ? '' : mine[0]?.rider_slug || '');
  const dropOptions = html`${open > 0 && html`<option value="">– niemand (freier Kaderplatz) –</option>`}
        ${mine.map((r) => html`<option value=${r.rider_slug}>${c.riderMap[r.rider_slug]?.name}${c.riderMap[r.rider_slug]?.inactive ? ' (inaktiv)' : ''}</option>`)}`;
  const [bid, setBid] = useState(0);
  const a = useAction();
  const dropRider = c.riderMap[drop];
  const faab = c.league.waiver_mode === 'faab';
  const { md, phase } = transferPhase(c);
  const freeMove = () => a.run(async () => {
    await rpc('free_move', { p_league: c.league.id, p_add: add.pcs_slug, p_drop: drop || null });
    onDone();
  });
  if (phase === 'free') return html`<section class="card stack">
    <h3>Sofort tauschen</h3>
    <p class="muted small">Freie Phase: Der Wechsel passiert sofort und gilt ab ${md.name} (Stichtag ${fmtDeadline(md.deadline)}).
      Bis dahin kannst du beliebig oft tauschen – der abgegebene Fahrer ist sofort für alle frei.</p>
    <div>Holen: <${RiderCell} r=${add} /></div>
    <label>Dafür abgeben
      <select value=${drop} onChange=${(e) => setDrop(e.target.value)}>${dropOptions}</select></label>
    <div class="row">
      <button class="primary" disabled=${a.busy || (!drop && open <= 0)} onClick=${freeMove}>Jetzt tauschen</button>
      <button class="ghost" onClick=${onCancel}>Abbrechen</button>
    </div>
    <${Msg} msg=${a.msg} />
  </section>`;
  const submit = (immediate) => a.run(async () => {
    await rpc('submit_waiver', { p_league: c.league.id, p_add: add.pcs_slug, p_drop: drop || null, p_bid: faab ? +bid : 0, p_immediate: immediate });
    onDone();
  });

  return html`<section class="card stack">
    <h3>Waiver-Antrag</h3>
    <div>Holen: <${RiderCell} r=${add} /></div>
    <label>Dafür abgeben
      <select value=${drop} onChange=${(e) => setDrop(e.target.value)}>${dropOptions}</select></label>
    ${faab && html`<label>Gebot (0–${c.me.budget_left})<input type="number" min="0" max=${c.me.budget_left} value=${bid} onInput=${(e) => setBid(e.target.value)} /></label>`}
    <div class="row">
      <button class="primary" disabled=${a.busy || (!drop && open <= 0)} onClick=${() => submit(false)}>Antrag stellen</button>
      ${dropRider?.inactive && html`<button disabled=${a.busy} onClick=${() => submit(true)}
        title="Bei Karriereende oder Sperre sofort ersetzen">Sofort ersetzen</button>`}
      <button class="ghost" onClick=${onCancel}>Abbrechen</button>
    </div>
    <${Msg} msg=${a.msg} />
  </section>`;
}
