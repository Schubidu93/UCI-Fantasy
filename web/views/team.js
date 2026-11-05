import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { sb, q, rpc, useLoad, useAction, Msg, Loading, RiderCell, fmtDate, fmtPts, SOURCE_LABEL, budgetRelevant, useRiderPoints } from '../lib.js';

import { NextDeadline, fmtDeadline } from './deadline.js';

export function Team({ c }) {
  const [mid, setMid] = useState(c.me?.id || c.managers[0]?.id);
  const pts = useLoad(() => rpc('league_points', { p_league: c.league.id }), [c.league.id]);
  const m = c.managerMap[mid];
  const isMe = c.me && mid === c.me.id;

  return html`<div class="stack">
    ${isMe && html`<${NextDeadline} c=${c} compact />`}
    <div class="row between">
      <label class="inline">Team
        <select value=${mid} onChange=${(e) => setMid(e.target.value)}>
          ${c.managers.map((x) => html`<option value=${x.id}>${x.team_name}${x.id === c.me?.id ? ' (du)' : ''}</option>`)}
        </select></label>
      ${m && budgetRelevant(c.league) && html`<span class="muted">Restbudget ${m.budget_left}${c.league.waiver_mode === 'faab' ? ' (FAAB)' : ''}</span>`}
    </div>
    ${!pts.data ? html`<${Loading} error=${pts.error} />` : html`<${Roster} c=${c} managerId=${mid} points=${pts.data} />`}
    ${isMe && c.league.scoring_mode === 'lineup' && html`<${Lineup} c=${c} />`}
    ${isMe && html`<${TeamName} c=${c} />`}
    ${c.league.status === 'active' && c.me && html`<${Trades} c=${c} />`}
  </div>`;
}

function Roster({ c, managerId, points }) {
  const entries = c.active.filter((r) => r.manager_id === managerId);
  const past = c.roster.filter((r) => r.manager_id === managerId && r.released_on);
  const started = c.matchdays.filter((md) => md.starts_on <= new Date().toISOString().slice(0, 10));
  const p = (slug, md) => points.filter((x) => x.manager_id === managerId && x.rider_slug === slug && (!md || x.matchday_id === md))
    .reduce((s, x) => s + Number(x.points), 0);
  const total = points.filter((x) => x.manager_id === managerId).reduce((s, x) => s + Number(x.points), 0);

  return html`<section class="card">
    <div class="row between"><h2>Kader</h2><span class="big">${fmtPts(total)} <span class="muted small">Punkte</span></span></div>
    <div class="scroll-x"><table class="tbl">
      <thead><tr><th>Fahrer</th><th class="num">Preis</th>
        ${started.map((md) => html`<th class="num" title=${md.name}>${md.name}</th>`)}
        <th class="num">Gesamt</th></tr></thead>
      <tbody>
        ${entries.sort((a, b) => p(b.rider_slug) - p(a.rider_slug)).map((r) => html`<tr key=${r.id}>
          <td><${RiderCell} r=${c.riderMap[r.rider_slug]} />
            ${r.source !== 'draft' && html`<span class="tag">${SOURCE_LABEL[r.source]} ab ${fmtDate(r.acquired_on)}</span>`}</td>
          <td class="num">${r.price}</td>
          ${started.map((md) => html`<td class="num">${fmtPts(p(r.rider_slug, md.id))}</td>`)}
          <td class="num"><strong>${fmtPts(p(r.rider_slug))}</strong></td></tr>`)}
      </tbody>
    </table></div>
    ${past.length > 0 && html`<details><summary>Abgegebene Fahrer (${past.length})</summary>
      <ul class="list compact">${past.map((r) => html`<li key=${r.id}>
        <span>${c.riderMap[r.rider_slug]?.name || r.rider_slug}</span>
        <span class="muted">${fmtDate(r.acquired_on)} – ${fmtDate(r.released_on)} · ${fmtPts(p(r.rider_slug))} Pkt.</span></li>`)}</ul>
    </details>`}
  </section>`;
}

function Lineup({ c }) {
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
      <label class="check"><input type="checkbox" checked=${sel.has(r.rider_slug)} onChange=${() => toggle(r.rider_slug)} />
        <${RiderCell} r=${c.riderMap[r.rider_slug]} /></label></li>`)}</ul>
    <div class="row">
      <button class="primary" disabled=${a.busy || sel.size !== size}
        onClick=${() => a.run(() => rpc('set_lineup', { p_matchday: md.id, p_riders: [...sel] }), 'Aufstellung gespeichert.')}>
        Speichern (${sel.size}/${size})</button>
    </div>
    <${Msg} msg=${a.msg} />
  </section>`;
}

function TeamName({ c }) {
  const [name, setName] = useState(c.me.team_name);
  const a = useAction();
  return html`<details class="card"><summary>Teamname ändern</summary>
    <form class="row" onSubmit=${(e) => { e.preventDefault(); a.run(async () => { await rpc('set_team_name', { p_league: c.league.id, p_team_name: name }); c.reload(); }, 'Gespeichert.'); }}>
      <input value=${name} onInput=${(e) => setName(e.target.value)} /><button disabled=${a.busy}>Speichern</button>
    </form><${Msg} msg=${a.msg} /></details>`;
}

const TRADE_STATUS = { proposed: 'offen', accepted: 'angenommen – wird zum nächsten Stichtag ausgeführt', declined: 'abgelehnt',
  cancelled: 'zurückgezogen', vetoed: 'Veto des Admins', done: 'ausgeführt', failed: 'gescheitert' };

function Trades({ c }) {
  const trades = useLoad(() => q(sb.from('trades').select('*').eq('league_id', c.league.id).order('created_at', { ascending: false }).limit(50)), [c.league.id]);
  const claims = useLoad(() => q(sb.from('waiver_claims').select('drop_rider').eq('manager_id', c.me.id).eq('status', 'pending')), [c.me.id]);
  const [partner, setPartner] = useState('');
  const [give, setGive] = useState([]);
  const [take, setTake] = useState([]);
  const [drop, setDrop] = useState([]);          // zusätzlich entlassen (wenn ich mehr bekomme)
  const [accept, setAccept] = useState(null);    // Angebot, das ich gerade annehme (mit Entlassungen)
  const a = useAction();
  const pts = useRiderPoints(c.league.gender);
  const name = (s) => c.riderMap[s]?.name || s;
  const withPts = (s) => html`${name(s)} <span class="muted small">${fmtPts(pts[s] || 0)}</span>`;
  const sumPts = (list) => list.reduce((x, s) => x + (pts[s] || 0), 0);
  const mine = c.active.filter((r) => r.manager_id === c.me.id);
  const theirs = c.active.filter((r) => r.manager_id === partner);
  const openSlots = c.league.roster_size - mine.length;
  const pendingDrops = new Set((claims.data || []).map((x) => x.drop_rider).filter(Boolean));
  const flip = (list, set, slug) => set(list.includes(slug) ? list.filter((x) => x !== slug) : [...list, slug]);
  const act = (fn, args) => a.run(async () => { await rpc(fn, args); trades.reload(); c.reload(); });
  // Fahrer, die ich zusätzlich entlassen muss, wenn ich mehr bekomme als ich abgebe
  const needDrop = (getN, giveN) => Math.max(0, getN - giveN - openSlots);
  const myNeed = needDrop(take.length, give.length);
  const DropPicker = ({ exclude, need, sel, set }) => html`<div class="drop-pick">
    <h4>Zusätzlich entlassen (${sel.length}/${need})</h4>
    <p class="muted small">Du bekommst mehr Fahrer als du abgibst – damit der Kader nicht zu groß wird. Fahrer aus offenen Waiver-Anträgen sind ausgenommen.</p>
    ${mine.filter((r) => !exclude.includes(r.rider_slug)).map((r) => html`<label class="check" key=${r.id}>
      <input type="checkbox" disabled=${pendingDrops.has(r.rider_slug)} checked=${sel.includes(r.rider_slug)} onChange=${() => flip(sel, set, r.rider_slug)} />
      ${name(r.rider_slug)}${pendingDrops.has(r.rider_slug) ? html` <span class="muted small">(Waiver-Antrag)</span>` : html` <span class="muted small">${fmtPts(pts[r.rider_slug] || 0)}</span>`}</label>`)}
  </div>`;

  return html`<section class="card stack">
    <h3>Tausch</h3>
    <p class="muted small">Auch ungleich möglich (z. B. 1 gegen 2): Wer mehr Fahrer bekommt, entlässt dafür eigene. Beide müssen zustimmen;
      danach hat der Admin 24 Stunden Vetorecht. Ausgeführt wird zum nächsten Stichtag.</p>
    ${trades.data && trades.data.length > 0 && html`<ul class="list">${trades.data.map((t) => {
      const incoming = t.to_manager === c.me.id;
      const vetoOpen = t.status === 'accepted' && Date.now() < new Date(t.accepted_at).getTime() + 864e5;
      const need = needDrop(t.give_riders.length, t.take_riders.length);
      return html`<li key=${t.id} class="stack-sm">
        <div><strong>${c.managerMap[t.from_manager]?.team_name}</strong> gibt ${t.give_riders.map(name).join(', ')} <span class="muted small">(${fmtPts(sumPts(t.give_riders))})</span>
          ↔ <strong>${c.managerMap[t.to_manager]?.team_name}</strong> gibt ${t.take_riders.map(name).join(', ')} <span class="muted small">(${fmtPts(sumPts(t.take_riders))})</span>
          ${(t.from_drop?.length || t.to_drop?.length) ? html`<div class="muted small">entlassen: ${[...(t.from_drop || []), ...(t.to_drop || [])].map(name).join(', ')}</div>` : ''}</div>
        <div class="row"><span class="tag">${TRADE_STATUS[t.status]}</span>
          ${incoming && t.status === 'proposed' && html`
            <button class="small primary" onClick=${() => (need ? setAccept({ id: t.id, need, drop: [], exclude: t.take_riders })
              : act('respond_trade', { p_trade: t.id, p_accept: true }))}>Annehmen</button>
            <button class="small" onClick=${() => act('respond_trade', { p_trade: t.id, p_accept: false })}>Ablehnen</button>`}
          ${t.from_manager === c.me.id && ['proposed', 'accepted'].includes(t.status) && html`
            <button class="small ghost" onClick=${() => act('cancel_trade', { p_trade: t.id })}>Zurückziehen</button>`}
          ${c.isAdmin && vetoOpen && html`<button class="small danger" onClick=${() => act('veto_trade', { p_trade: t.id })}>Veto</button>`}
        </div>
        ${accept?.id === t.id && html`<div class="stack">
          <${DropPicker} exclude=${accept.exclude} need=${accept.need} sel=${accept.drop} set=${(d) => setAccept({ ...accept, drop: d })} />
          <div class="row"><button class="primary" disabled=${a.busy || accept.drop.length !== accept.need}
            onClick=${() => act('respond_trade', { p_trade: t.id, p_accept: true, p_drop: accept.drop }).then(() => setAccept(null))}>Annehmen und entlassen</button>
            <button class="ghost" onClick=${() => setAccept(null)}>Abbrechen</button></div></div>`}
      </li>`;
    })}</ul>`}
    <details><summary>Neues Angebot</summary>
      <div class="stack">
        <label>Tauschpartner
          <select value=${partner} onChange=${(e) => { setPartner(e.target.value); setTake([]); }}>
            <option value="">– wählen –</option>
            ${c.managers.filter((m) => m.id !== c.me.id).map((m) => html`<option value=${m.id}>${m.team_name}</option>`)}
          </select></label>
        ${partner && html`<div class="grid2">
          <div><h4>Ich gebe</h4>${mine.map((r) => html`<label class="check" key=${r.id}>
            <input type="checkbox" checked=${give.includes(r.rider_slug)} onChange=${() => { flip(give, setGive, r.rider_slug); setDrop(drop.filter((x) => x !== r.rider_slug)); }} /> ${withPts(r.rider_slug)}</label>`)}</div>
          <div><h4>Ich bekomme</h4>${theirs.map((r) => html`<label class="check" key=${r.id}>
            <input type="checkbox" checked=${take.includes(r.rider_slug)} onChange=${() => flip(take, setTake, r.rider_slug)} /> ${withPts(r.rider_slug)}</label>`)}</div>
        </div>
        ${(give.length > 0 || take.length > 0) && html`<p class="small trade-sum">Punkte ${new Date().getFullYear()}: du gibst <strong>${fmtPts(sumPts(give))}</strong>, du bekommst <strong>${fmtPts(sumPts(take))}</strong></p>`}
        ${myNeed > 0 && html`<${DropPicker} exclude=${give} need=${myNeed} sel=${drop} set=${setDrop} />`}
        ${give.length > take.length && take.length > 0 && html`<p class="muted small">Du gibst mehr Fahrer ab – ${c.managerMap[partner]?.team_name} wählt bei der Annahme, wen er dafür entlässt.</p>`}
        <button class="primary" disabled=${a.busy || !give.length || !take.length || drop.length !== myNeed}
          onClick=${() => act('propose_trade', { p_league: c.league.id, p_to: partner, p_give: give, p_take: take, p_drop: myNeed ? drop : [] })
            .then(() => { setGive([]); setTake([]); setDrop([]); })}>
          Angebot senden</button>`}
      </div>
    </details>
    <${Msg} msg=${a.msg} />
  </section>`;
}
