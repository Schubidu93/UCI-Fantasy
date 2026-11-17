// Admin → Protokoll: Änderungen des Admins und wichtige Liga-Ereignisse
import { html, useState } from '../../vendor/preact-htm.js';
import { sb, q, useLoad, Loading, fmtDateTime } from '../../lib.js';
import { SPORT } from '../../sport/index.js';

const ACTIONS = { override: 'Punktekorrektur', roster_fix: 'Kaderkorrektur', settings: 'Einstellungen', start_draft: 'Draft gestartet',
  offline_import: 'Offline-Kader fixiert', veto_trade: 'Tausch-Veto', transfer_admin: 'Admin übertragen', remove_manager: 'Manager entfernt',
  mark_inactive: `${SPORT.one} inaktiv` };

export function Log({ c }) {
  const log = useLoad(() => q(sb.from('admin_log').select('*').eq('league_id', c.league.id).order('created_at', { ascending: false }).limit(200)), [c.league.id]);
  if (!log.data) return html`<${Loading} error=${log.error} />`;
  return html`<section class="card"><h3>Protokoll</h3>
    ${log.data.length === 0 ? html`<p class="muted">Noch keine Einträge.</p>` : html`<ul class="list compact">${log.data.map((e) => html`<li key=${e.id}>
      <span><strong>${ACTIONS[e.action] || e.action}</strong> <span class="muted small">${describe(c, e.details)}</span></span>
      <span class="muted small">${fmtDateTime(e.created_at)}</span></li>`)}</ul>`}</section>`;
}

function describe(c, d) {
  if (!d) return '';
  const parts = [];
  if (d.manager) parts.push(c.managerMap[d.manager]?.team_name || d.team);
  if (d.rider) parts.push(c.riderMap[d.rider]?.name || d.rider);
  if (d.add) parts.push(`+ ${c.riderMap[d.add]?.name || d.add}`);
  if (d.drop) parts.push(`− ${c.riderMap[d.drop]?.name || d.drop}`);
  if (d.points !== undefined) parts.push(`${d.points ?? 'aufgehoben'} Pkt.`);
  if (d.reason) parts.push(d.reason);
  return parts.filter(Boolean).join(' · ');
}
