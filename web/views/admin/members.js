// Admin → Mitglieder: Teams, Plätze, Admin-Rechte
import { html, useState } from '../../vendor/preact-htm.js';
import { rpc, useAction, Msg } from '../../lib.js';

export function Members({ c }) {
  const link = `${location.origin}${location.pathname}#/join/${c.league.invite_code}`;
  const [ph, setPh] = useState('');
  const a = useAction();
  const act = (fn, args, ok) => a.run(async () => { await rpc(fn, args); c.reload(); }, ok);
  return html`<section class="card stack">
    <h3>Einladen</h3>
    <div class="row"><input readonly value=${link} onFocus=${(e) => e.target.select()} />
      <button onClick=${() => navigator.clipboard.writeText(link).then(() => a.setMsg({ ok: true, text: 'Link kopiert.' }))}>Kopieren</button></div>
    <p class="muted small">Code: <code>${c.league.invite_code}</code> · ${c.managers.length}/${c.league.max_managers} Plätze</p>

    <h3>Manager</h3>
    <ul class="list">${c.managers.map((m) => html`<li key=${m.id}>
      <span>${m.team_name} ${m.user_id === c.league.admin_user ? html`<span class="tag">Admin</span>` : ''}
        ${!m.user_id ? html`<span class="tag">frei – per Einladungslink übernehmbar</span>` : ''}</span>
      <span class="row">
        ${m.user_id && m.user_id !== c.league.admin_user && html`<button class="small ghost"
          onClick=${() => confirm(`Admin-Rechte an ${m.team_name} übertragen?`) && act('transfer_admin', { p_league: c.league.id, p_manager: m.id }, 'Übertragen.')}>Zum Admin machen</button>`}
        ${m.user_id !== c.league.admin_user && html`<button class="small danger"
          onClick=${() => confirm(c.league.status === 'setup' ? `${m.team_name} entfernen?` : `${m.team_name} vom Konto lösen? Der Kader bleibt und kann von einem Nachfolger übernommen werden.`)
            && act('remove_manager', { p_league: c.league.id, p_manager: m.id })}>
          ${c.league.status === 'setup' ? 'Entfernen' : 'Konto lösen'}</button>`}
      </span></li>`)}</ul>

    ${c.league.status === 'setup' && html`<form class="row" onSubmit=${(e) => { e.preventDefault(); act('add_placeholder_manager', { p_league: c.league.id, p_team_name: ph }, 'Platz angelegt.').then(() => setPh('')); }}>
      <input placeholder="Team ohne Konto anlegen (z. B. für Offline-Draft)" value=${ph} onInput=${(e) => setPh(e.target.value)} />
      <button disabled=${!ph.trim() || a.busy}>Anlegen</button></form>`}
    <${Msg} msg=${a.msg} />
  </section>`;
}

