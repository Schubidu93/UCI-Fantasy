import { html, useState, useEffect, useRef } from '../vendor/preact-htm.js';
import { sb, q, rpc, useLoad, useAction, Msg, RiderCell, RiderPicker } from '../lib.js';
import { DraftReport } from './report.js';

// Abstand zwischen Server- und Geräteuhr, damit der Countdown überall gleich läuft
let clockOffset = 0;
async function syncClock() {
  const t0 = Date.now();
  const server = await rpc('server_now');
  clockOffset = new Date(server).getTime() - (t0 + Date.now()) / 2;
}
const serverNow = () => Date.now() + clockOffset;

export function Draft({ c }) {
  const { league } = c;
  if (league.status === 'setup') return html`<${DraftLobby} c=${c} />`;
  return html`<${DraftRoom} c=${c} />`;
}

function DraftLobby({ c }) {
  const a = useAction();
  const offline = c.league.draft_mode === 'offline';
  const snake = c.league.draft_mode === 'snake';
  return html`<section class="card stack">
    <h2>Draft</h2>
    ${offline
      ? html`<p>Diese Liga nutzt einen <strong>Offline-Draft</strong>. Der Admin trägt die Kader unter „Admin“ ein.</p>`
      : snake
      ? html`<p><strong>Snake-Draft:</strong> Die Manager wählen reihum je einen Fahrer, in jeder Runde dreht sich die
          Reihenfolge um (1–2–3 … 3–2–1). Pro Pick gibt es ${c.league.bid_seconds} Sekunden – danach wird automatisch der
          beste freie Fahrer nach UCI-Rang gewählt. Die Reihenfolge wird beim Start ausgelost.</p>`
      : c.league.draft_mode === 'blind'
      ? html`<p><strong>Blind-Auktion</strong> mit ${c.league.budget} Budgetpunkten pro Manager. Pro Fahrer haben alle
          ${c.league.bid_seconds} Sekunden für ein verdecktes Gebot – das höchste gewinnt sofort. Bei Gleichstand wird um +1 gestochen.
          Reihenfolge: ${c.league.draft_order === 'ranking' ? 'UCI-Rangliste' : 'reihum nominieren'}.</p>`
      : html`<p>Live-Auktion mit ${c.league.budget} Budgetpunkten pro Manager. Jedes Gebot setzt
          die Uhr auf ${c.league.bid_seconds} Sekunden zurück. Reihenfolge: ${c.league.draft_order === 'ranking' ? 'UCI-Rangliste' : 'reihum nominieren'}.</p>`}
    ${!offline && html`<${DraftSchedule} c=${c} />`}
    ${c.league.keeper_count > 0 && c.league.prev_league && html`<${Keepers} c=${c} />`}
    <h3>Manager (${c.managers.length}/${c.league.max_managers})</h3>
    <ul class="list">${c.managers.map((m) => html`<li key=${m.id}>${m.team_name}
      ${m.user_id ? '' : html`<span class="tag">Platzhalter</span>`}</li>`)}</ul>
    ${c.isAdmin && !offline && html`<div class="row">
      <button class="primary" disabled=${a.busy || c.managers.length < 2}
        onClick=${() => a.run(async () => { await rpc('start_draft', { p_league: c.league.id }); c.reload(); })}>Draft starten</button>
      <span class="muted small">Alle sollten jetzt im Draft-Raum sein.</span></div>`}
    ${c.isAdmin && offline && html`<a class="button primary" href=${`#/league/${c.league.id}/admin/import`}>Kader eintragen</a>`}
    ${!c.isAdmin && !offline && html`<p class="muted">Warte, bis der Admin den Draft startet – diese Seite aktualisiert sich dann.</p>`}
    <${Msg} msg=${a.msg} />
    <${AutoReload} c=${c} />
  </section>`;
}

// Keeper aus der Vorsaison wählen (nur vor dem Draft)
function Keepers({ c }) {
  const L = c.league.id;
  const opts = useLoad(() => (c.me ? rpc('keeper_options', { p_league: L }) : Promise.resolve([])), [L]);
  const all = useLoad(() => q(sb.from('keepers').select('*').eq('league_id', L)), [L]);
  const [sel, setSel] = useState(null);
  const a = useAction();
  if (!opts.data || !all.data) return null;
  const chosen = sel || new Set(opts.data.filter((o) => o.chosen).map((o) => o.rider_slug));
  const flip = (slug) => { const s = new Set(chosen); s.has(slug) ? s.delete(slug) : s.add(slug); setSel(s); };
  const sum = opts.data.filter((o) => chosen.has(o.rider_slug)).reduce((s, o) => s + o.price, 0);
  return html`<div class="schedule">
    <strong>Keeper (bis zu ${c.league.keeper_count})</strong>
    <p class="muted small">Behalte Fahrer aus der Vorsaison – zum Vorjahrespreis + ${c.league.keeper_surcharge}. Sie stehen beim Draft-Start fest in deinem Kader.</p>
    ${opts.data.length === 0 ? html`<p class="muted small">Kein Vorjahreskader gefunden.</p>` : html`
      <ul class="list compact">${opts.data.map((o) => html`<li key=${o.rider_slug}>
        <label class="check"><input type="checkbox" checked=${chosen.has(o.rider_slug)} onChange=${() => flip(o.rider_slug)} />
          <${RiderCell} r=${c.riderMap[o.rider_slug]} /></label>
        <span class="muted small">${o.prev_price} → <strong>${o.price}</strong></span></li>`)}</ul>
      <div class="row">
        <button class="primary" disabled=${a.busy || chosen.size > c.league.keeper_count}
          onClick=${() => a.run(async () => { await rpc('set_keepers', { p_league: L, p_riders: [...chosen] }); setSel(null); opts.reload(); all.reload(); }, 'Keeper gespeichert.')}>
          Keeper speichern (${chosen.size}/${c.league.keeper_count} · ${sum} Pkt.)</button>
      </div>`}
    <${Msg} msg=${a.msg} />
    ${all.data.length > 0 && html`<details><summary>Keeper aller Manager (${all.data.length})</summary>
      <ul class="list compact">${all.data.map((k) => html`<li key=${k.rider_slug}><span>${c.riderMap[k.rider_slug]?.name || k.rider_slug}</span>
        <span class="muted small">${c.managerMap[k.manager_id]?.team_name} · ${k.price}</span></li>`)}</ul></details>`}
  </div>`;
}

// Geplanter Draft: Admin setzt Datum/Uhrzeit, alle sehen den Countdown; bei 0 startet der Draft automatisch
function DraftSchedule({ c }) {
  const at = c.league.draft_at ? new Date(c.league.draft_at) : null;
  const toLocal = (d) => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 16); };
  const [val, setVal] = useState(at ? toLocal(at) : '');
  const [now, setNow] = useState(serverNow());
  const a = useAction();
  const starting = useRef(false);
  useEffect(() => { const t = setInterval(() => setNow(serverNow()), 1000); syncClock().catch(() => {}); return () => clearInterval(t); }, []);
  const left = at ? Math.max(0, Math.floor((at.getTime() - now) / 1000)) : null;
  // Bei 0 alle 2 s versuchen (Uhren von Gerät und Server weichen minimal ab; nur der erste Aufruf wirkt)
  useEffect(() => {
    if (!at || left !== 0) return;
    const tryStart = () => {
      if (starting.current) return;
      starting.current = true;
      rpc('start_scheduled_draft', { p_league: c.league.id }).then((ok) => { if (ok) c.reload(); })
        .catch(() => {}).finally(() => { starting.current = false; });
    };
    tryStart();
    const t = setInterval(tryStart, 2000);
    return () => clearInterval(t);
  }, [left === 0, c.league.draft_at]);
  const fmt = (sec) => {
    const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
    return (d ? `${d} T ` : '') + [h, m, s].map((x) => String(x).padStart(2, '0')).join(':');
  };
  return html`<div class="schedule">
    ${at ? html`<div class="row between">
        <div><div class="muted small">Draft-Start</div><strong>${at.toLocaleString('de-DE', { dateStyle: 'full', timeStyle: 'short' })}</strong></div>
        <div class="countdown">${left > 0 ? fmt(left) : 'startet …'}</div></div>`
      : html`<p class="muted small">Noch kein Termin für den Draft festgelegt.${c.isAdmin ? ' Lege unten einen Termin fest oder starte den Draft direkt.' : ' Der Admin legt ihn fest – du bekommst dann eine Push-Nachricht.'}</p>`}
    ${c.isAdmin && html`<div class="row">
      <input type="datetime-local" value=${val} onInput=${(e) => setVal(e.target.value)} />
      <button disabled=${a.busy || !val} onClick=${() => a.run(async () => {
        await rpc('schedule_draft', { p_league: c.league.id, p_at: new Date(val).toISOString() }); c.reload(); }, 'Termin gespeichert.')}>Termin speichern</button>
      ${at && html`<button class="ghost" disabled=${a.busy} onClick=${() => a.run(async () => {
        await rpc('schedule_draft', { p_league: c.league.id, p_at: null }); setVal(''); c.reload(); })}>Termin löschen</button>`}
    </div>`}
    <${Msg} msg=${a.msg} />
  </div>`;
}

// Prüft im Hintergrund, ob jemand beigetreten ist oder der Draft gestartet wurde
function AutoReload({ c }) {
  useEffect(() => {
    const t = setInterval(async () => {
      const [l, m] = await Promise.all([
        q(sb.from('leagues').select('status').eq('id', c.league.id)),
        q(sb.from('managers').select('id, team_name, user_id').eq('league_id', c.league.id)),
      ]).catch(() => [[], null]);
      const sig = (list) => list.map((x) => x.id + x.team_name + x.user_id).sort().join();
      if ((l[0] && l[0].status !== c.league.status) || (m && sig(m) !== sig(c.managers))) c.reload();
    }, 4000);
    return () => clearInterval(t);
  }, [c.league.status, c.managers]);
  return null;
}

function DraftRoom({ c }) {
  const L = c.league.id;
  const [d, setD] = useState(null);
  const [lots, setLots] = useState([]);
  const [now, setNow] = useState(serverNow());
  const [amount, setAmount] = useState('');
  const [sealed, setSealed] = useState(null);      // Blind-Auktion: eigenes verdecktes Gebot
  const [lastBids, setLastBids] = useState([]);    // Blind-Auktion: offengelegte Gebote des letzten Fahrers
  const a = useAction();
  const lastLot = useRef(null);
  const blind = c.league.draft_mode === 'blind';
  const loadSealed = async () => {
    if (!blind || !c.me) return;
    const [x] = await q(sb.from('draft_sealed').select('amount').eq('league_id', L).eq('manager_id', c.me.id));
    setSealed(x ? x.amount : null);
  };
  const ticking = useRef(false);

  const load = async () => {
    const [st] = await q(sb.from('draft_state').select('*').eq('league_id', L));
    setD(st);
    const key = st && `${st.lot_no}|${st.status}|${st.phase}|${st.nominator}`;
    if (st && key !== lastLot.current) {
      lastLot.current = key;
      const ls = await q(sb.from('draft_lots').select('*').eq('league_id', L).order('lot_no', { ascending: false }).limit(200));
      setLots(ls);
      if (blind && ls[0]) setLastBids(await q(sb.from('draft_bids').select('*').eq('league_id', L).eq('lot_no', ls[0].lot_no).order('id')));
      await loadSealed();
      c.reload();
      setAmount('');
    }
  };

  useEffect(() => {
    syncClock().catch(() => {});
    load();
    const ch = sb.channel(`draft-${L}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'draft_state', filter: `league_id=eq.${L}` },
        (p) => { if (p.new) { setD(p.new); load(); } })
      .subscribe();
    const poll = setInterval(load, 1500);            // Rückfall, falls Realtime hakt
    const clock = setInterval(() => setNow(serverNow()), 200);
    return () => { sb.removeChannel(ch); clearInterval(poll); clearInterval(clock); };
  }, [L]);

  // Uhr abgelaufen → Zuschlag auslösen (jeder Client darf, nur der erste wirkt)
  const remaining = d?.deadline ? Math.max(0, (new Date(d.deadline).getTime() - now) / 1000) : null;
  useEffect(() => {
    if (d?.status === 'running' && remaining === 0 && !ticking.current) {
      ticking.current = true;
      rpc('draft_tick', { p_league: L }).catch(() => {}).finally(() => { ticking.current = false; load(); });
    }
  }, [remaining === 0, d?.deadline]);

  // Du bist dran: Vibration, Tab-Titel und – wenn die App im Hintergrund ist – eine Benachrichtigung
  const myTurnNow = !!(c.me && d?.status === 'running' && d.nominator === c.me.id && !d.current_rider);
  useEffect(() => {
    if (!myTurnNow) return;
    const title = document.title;
    document.title = '⏰ Du bist dran! – ' + title;
    try { navigator.vibrate?.([200, 100, 200]); } catch (_) {}
    if (document.hidden && 'Notification' in window && Notification.permission === 'granted') {
      navigator.serviceWorker?.getRegistration().then((reg) => reg?.showNotification('⏰ Du bist dran!',
        { body: `${c.league.name}: Dein Pick im Draft.`, tag: 'draft-turn', data: { url: location.hash } })).catch(() => {});
    }
    return () => { document.title = title; };
  }, [myTurnNow, d?.lot_no]);

  if (!d) return html`<p class="muted">Lädt …</p>`;
  if (d.status === 'done') return html`<${DraftSummary} c=${c} lots=${lots} />`;
  if (d.phase === 'snake') return html`<${SnakeRoom} c=${c} d=${d} lots=${lots} remaining=${remaining} load=${load} />`;

  const me = c.me;
  const open = (m) => c.league.roster_size - c.active.filter((r) => r.manager_id === m.id).length;
  const maxBid = (m) => (open(m) <= 0 ? 0 : m.budget_left - (open(m) - 1));
  const rider = c.riderMap[d.current_rider];
  const minNext = Math.max(1, d.current_bid + 1);
  const iAmHigh = me && d.current_bidder === me.id;
  const canBid = me && d.status === 'running' && rider && remaining > 0 && !iAmHigh && open(me) > 0 && maxBid(me) >= minNext;
  const bid = (v) => a.run(async () => { await rpc('draft_bid', { p_league: L, p_amount: v }); setAmount(''); await load(); });
  const nominatorName = c.managerMap[d.nominator]?.team_name;
  const myTurn = me && d.nominator === me.id;
  const asAdmin = (r, verb) => myTurn || adminConfirm(r, nominatorName, verb);
  const drafted = new Set(lots.map((l) => l.rider_slug));
  const free = c.riders.filter((r) => !c.owner[r.pcs_slug] && !r.inactive);

  return html`<div class="draft">
    <section class="card auction">
      <div class="row between">
        <span class="tag">${d.status === 'paused' ? 'Pausiert' : d.phase === 'fill' ? 'Auffüllphase' : `Los ${d.lot_no}`}</span>
        ${c.isAdmin && html`<button class="small ghost" disabled=${a.busy}
          onClick=${() => a.run(async () => { await rpc('pause_draft', { p_league: L, p_pause: d.status === 'running' }); load(); })}>
          ${d.status === 'running' ? 'Pausieren' : 'Fortsetzen'}</button>`}
      </div>

      ${rider && blind ? html`
        <${BlindLot} c=${c} d=${d} rider=${rider} remaining=${remaining} sealed=${sealed} maxBid=${maxBid} open=${open}
          onBid=${(v) => a.run(async () => { await rpc('draft_blind_bid', { p_league: L, p_amount: v }); await loadSealed(); await load(); })}
          onRaise=${(v) => a.run(async () => { await rpc('draft_bid', { p_league: L, p_amount: v }); await load(); })} busy=${a.busy} />
      ` : rider ? html`
        <div class="lot">
          <div class="lot-rider"><${RiderCell} r=${rider} /></div>
          <div class=${`clock ${remaining !== null && remaining < 5 ? 'hot' : ''}`} aria-live="off">
            ${d.status === 'paused' ? '⏸' : remaining !== null ? Math.ceil(remaining) : ''}
          </div>
        </div>
        <div class="bid-now">
          ${d.current_bid > 0
            ? html`Höchstgebot <strong>${d.current_bid}</strong> von <strong>${c.managerMap[d.current_bidder]?.team_name}</strong>${iAmHigh ? ' (du)' : ''}`
            : html`<span class="muted">Noch kein Gebot – ohne Gebot wird der Fahrer übersprungen.</span>`}
        </div>
        ${me && html`<div class="bid-controls">
          ${[0, 1, 4, 9].map((plus) => minNext + plus <= maxBid(me) && html`
            <button class=${plus === 0 ? 'primary' : ''} disabled=${!canBid || a.busy} onClick=${() => bid(minNext + plus)}>${minNext + plus}</button>`)}
          <form class="row" onSubmit=${(e) => { e.preventDefault(); if (amount) bid(+amount); }}>
            <input type="number" min=${minNext} max=${maxBid(me)} placeholder="eigenes Gebot" value=${amount}
              onInput=${(e) => setAmount(e.target.value)} disabled=${!canBid} />
            <button disabled=${!canBid || a.busy || !amount}>Bieten</button>
          </form>
          <span class="muted small">Dein Höchstgebot: ${maxBid(me)}</span>
        </div>`}
      ` : d.phase === 'fill' ? html`
        <p>Die Rangliste ist durch. Restplätze werden reihum mit freien Fahrern zum Preis 1 gefüllt.</p>
        ${myTurn && html`<div class="your-turn">⏰ Du bist dran!</div>`}
        <p>An der Reihe: <strong>${nominatorName}</strong>${myTurn ? ' – du!' : ''}</p>
        ${(myTurn || c.isAdmin) && html`<${RiderPicker} riders=${free} action="Für 1 holen"
          onPick=${(r) => asAdmin(r, 'holen') && a.run(async () => { await rpc('draft_fill_pick', { p_league: L, p_rider: r.pcs_slug }); load(); })} />`}
      ` : html`
        ${myTurn && html`<div class="your-turn">⏰ Du bist dran!</div>`}
        <p>An der Reihe zum Nominieren: <strong>${nominatorName}</strong>${myTurn ? ' – du!' : ''}</p>
        ${(myTurn || c.isAdmin) && html`<p class="muted small">${blind ? 'Danach bieten alle verdeckt.' : 'Der nominierte Fahrer startet mit deinem Gebot 1.'}</p>
          <${RiderPicker} riders=${free.filter((r) => !drafted.has(r.pcs_slug))} action="Nominieren"
          onPick=${(r) => asAdmin(r, 'nominieren') && a.run(async () => { await rpc('draft_nominate', { p_league: L, p_rider: r.pcs_slug }); load(); })} />`}
      `}
      <${Msg} msg=${a.msg} />
    </section>

    <section class="card">
      <h3>Manager</h3>
      <table class="tbl">
        <thead><tr><th>Team</th><th class="num">Budget</th><th class="num">Plätze frei</th><th class="num">Max.</th></tr></thead>
        <tbody>${c.managers.map((m) => html`<tr key=${m.id} class=${m.id === me?.id ? 'me' : ''}>
          <td>${m.team_name}</td><td class="num">${m.budget_left}</td><td class="num">${open(m)}</td><td class="num">${maxBid(m)}</td></tr>`)}</tbody>
      </table>
    </section>

    ${me && html`<section class="card">
      <h3>Mein Kader</h3>
      <${RosterMini} c=${c} managerId=${me.id} />
    </section>`}

    <section class="card">
      <h3>Letzte Zuschläge</h3>
      ${blind && lots[0] && lastBids.length > 0 && html`<p class="muted small">Gebote für ${c.riderMap[lots[0].rider_slug]?.name || lots[0].rider_slug}:
        ${lastBids.map((b, i) => html`${i ? ' · ' : ''}${c.managerMap[b.manager_id]?.team_name} <strong>${b.amount}</strong>`)}</p>`}
      <ul class="list compact">${lots.slice(0, 15).map((l) => html`<li key=${l.id}>
        <span>${c.riderMap[l.rider_slug]?.name || l.rider_slug}</span>
        <span class="muted">${l.manager_id ? `${c.managerMap[l.manager_id]?.team_name} · ${l.price}` : 'übersprungen'}</span></li>`)}</ul>
    </section>
  </div>`;
}

// Blind-Auktion: verdeckt bieten; bei Gleichstand Stechen um +1
function BlindLot({ c, d, rider, remaining, sealed, maxBid, open, onBid, onRaise, busy }) {
  const [val, setVal] = useState('');
  const me = c.me;
  const running = d.status === 'running' && remaining > 0;
  const clock = html`<div class=${`clock ${remaining !== null && remaining < 5 ? 'hot' : ''}`} aria-live="off">
    ${d.status === 'paused' ? '⏸' : remaining !== null ? Math.ceil(remaining) : ''}</div>`;
  const head = html`<div class="lot"><div class="lot-rider"><${RiderCell} r=${rider} /></div>${clock}</div>`;

  if (d.phase === 'tiebreak') {
    const tied = (d.tie_bidders || []).map((id) => c.managerMap[id]?.team_name).join(', ');
    const leader = c.managerMap[d.current_bidder]?.team_name;
    const iAmIn = me && (d.tie_bidders || []).includes(me.id);
    const iLead = me && d.current_bidder === me.id;
    const next = d.current_bid + 1;
    return html`${head}
      <div class="bid-now">⚖️ Gleichstand – Stechen zwischen <strong>${tied}</strong></div>
      <p>Vorn: <strong>${leader}</strong>${iLead ? ' (du)' : ''} mit <strong>${d.current_bid}</strong>.</p>
      <p class="muted small">Erhöht niemand um 1, ${iLead ? 'bekommst du' : `bekommt ${leader}`} den Fahrer.</p>
      ${iAmIn && !iLead && html`<div class="bid-controls">
        <button class="primary" disabled=${!running || busy || maxBid(me) < next} onClick=${() => onRaise(next)}>Auf ${next} erhöhen</button>
        <span class="muted small">${maxBid(me) < next ? 'Dein Budget reicht nicht für mehr.' : 'Nichts tun = aussteigen.'}</span></div>`}`;
  }

  const done = new Set(d.sealed_done || []);
  const bidders = c.managers.filter((m) => open(m) > 0 && maxBid(m) >= 1);
  const canBid = me && running && open(me) > 0 && maxBid(me) >= 1;
  const send = (v) => { onBid(v); setVal(''); };
  return html`${head}
    <div class="bid-now">${sealed ? html`Dein verdecktes Gebot: <strong>${sealed}</strong>` : html`<span class="muted">Verdeckt bieten – niemand sieht dein Gebot. Ohne Gebot wird der Fahrer übersprungen.</span>`}</div>
    ${me && html`<div class="bid-controls">
      ${[1, 5, 10, 20].filter((v) => v <= maxBid(me)).map((v) => html`
        <button class=${sealed === v ? 'primary' : ''} disabled=${!canBid || busy} onClick=${() => send(v)}>${v}</button>`)}
      <form class="row" onSubmit=${(e) => { e.preventDefault(); if (val) send(+val); }}>
        <input type="number" min="1" max=${maxBid(me)} placeholder="eigenes Gebot" value=${val}
          onInput=${(e) => setVal(e.target.value)} disabled=${!canBid} />
        <button disabled=${!canBid || busy || !val}>${sealed ? 'Ändern' : 'Bieten'}</button>
      </form>
      ${sealed && html`<button class="ghost small" disabled=${!canBid || busy} onClick=${() => send(0)}>Gebot zurückziehen</button>`}
      <span class="muted small">Dein Höchstgebot: ${maxBid(me)}</span>
    </div>`}
    <p class="muted small">Geboten: ${bidders.map((m, i) => html`${i ? ' · ' : ''}${done.has(m.id) ? '✓' : '…'} ${m.team_name}`)}
      ${' '}– haben alle geboten, wird sofort ausgewertet.</p>`;
}

// Admin wählt für einen anderen Manager: erst nachfragen, damit das nicht versehentlich passiert
function adminConfirm(r, team, verb) {
  return confirm(`Du bist im Admin-Modus und gerade nicht an der Reihe.\n\nWillst du wirklich ${r.name} für ${team || 'einen anderen Manager'} ${verb}?`);
}

// Snake-Draft: Reihenfolge 1…n, dann n…1, usw.
function snakeManager(order, pick) {
  const n = order.length;
  const round = Math.floor((pick - 1) / n), idx = (pick - 1) % n;
  return order[round % 2 === 0 ? idx : n - 1 - idx];
}

function SnakeRoom({ c, d, lots, remaining, load }) {
  const a = useAction();
  const L = c.league.id;
  const me = c.me;
  const order = [...c.managers].sort((x, y) => (x.draft_position ?? 99) - (y.draft_position ?? 99));
  const n = order.length;
  const total = n * c.league.roster_size;
  const round = Math.floor((d.lot_no - 1) / n) + 1;
  const myTurn = me && d.nominator === me.id;
  const picker = c.managerMap[d.nominator];
  const free = c.riders.filter((r) => !c.owner[r.pcs_slug] && !r.inactive && r.uci_rank);
  const next = [];
  for (let p = d.lot_no + 1; p <= Math.min(total, d.lot_no + 6); p++) next.push([p, snakeManager(order, p)]);
  const pick = (r) => (myTurn || adminConfirm(r, picker?.team_name, 'draften')) && a.run(async () => { await rpc('draft_snake_pick', { p_league: L, p_rider: r.pcs_slug }); await load(); });

  return html`<div class="draft">
    <section class="card auction">
      <div class="row between">
        <span class="tag">${d.status === 'paused' ? 'Pausiert' : `Pick ${d.lot_no} von ${total} · Runde ${round}`}</span>
        ${c.isAdmin && html`<button class="small ghost" disabled=${a.busy}
          onClick=${() => a.run(async () => { await rpc('pause_draft', { p_league: L, p_pause: d.status === 'running' }); load(); })}>
          ${d.status === 'running' ? 'Pausieren' : 'Fortsetzen'}</button>`}
      </div>
      <div class="lot">
        <div>
          <div class="muted small">An der Reihe</div>
          <div class="big">${picker?.team_name}${myTurn ? ' – du!' : ''}</div>
          ${myTurn && d.status === 'running' && html`<div class="your-turn">⏰ Du bist dran!</div>`}
        </div>
        <div class=${`clock ${remaining !== null && remaining < 10 ? 'hot' : ''}`} aria-live="off">
          ${d.status === 'paused' ? '⏸' : remaining !== null ? Math.ceil(remaining) : ''}
        </div>
      </div>
      ${(myTurn || c.isAdmin) && d.status === 'running'
        ? html`<p class="muted small">${myTurn ? 'Wähle deinen Fahrer.' : `Admin-Modus: Du bist nicht dran – ein Pick hier geht an ${picker?.team_name}.`}${" "}
            Läuft die Uhr ab, wird automatisch der beste freie Fahrer nach UCI-Rang gewählt.</p>
          <${RiderPicker} riders=${free} limit=${40} action="Wählen" onPick=${pick} />`
        : html`<p class="muted">Warte auf den Pick von ${picker?.team_name} …</p>`}
      <${Msg} msg=${a.msg} />
    </section>

    <section class="card">
      <h3>Nächste Picks</h3>
      <ol class="list compact">${next.map(([p, m]) => html`<li key=${p}><span>${m?.team_name}${m?.id === me?.id ? ' (du)' : ''}</span>
        <span class="muted">Pick ${p}</span></li>`)}</ol>
      ${next.length === 0 && html`<p class="muted small">Letzter Pick.</p>`}
    </section>

    ${me && html`<section class="card">
      <h3>Mein Kader (${c.active.filter((r) => r.manager_id === me.id).length}/${c.league.roster_size})</h3>
      <${RosterMini} c=${c} managerId=${me.id} />
    </section>`}

    <section class="card">
      <h3>Letzte Picks</h3>
      <ul class="list compact">${lots.slice(0, 15).map((l) => html`<li key=${l.id}>
        <span>${l.lot_no}. ${c.riderMap[l.rider_slug]?.name || l.rider_slug}</span>
        <span class="muted">${c.managerMap[l.manager_id]?.team_name}</span></li>`)}</ul>
    </section>
  </div>`;
}

function RosterMini({ c, managerId }) {
  const mine = c.active.filter((r) => r.manager_id === managerId);
  if (!mine.length) return html`<p class="muted">Noch leer.</p>`;
  return html`<ul class="list compact">${mine.map((r) => html`<li key=${r.id}>
    <span>${c.riderMap[r.rider_slug]?.name || r.rider_slug}</span><span class="muted">${r.price}</span></li>`)}</ul>`;
}

function DraftSummary({ c }) {
  return html`<${DraftReport} c=${c} />`;
}
