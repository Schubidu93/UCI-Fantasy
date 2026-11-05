// Rennen der Saison mit Ergebnislisten (Rang, Fahrer, Team, Zeit, UCI-Punkte)
import { html, useState, useMemo } from '../vendor/preact-htm.js';
import { sb, q, all, useLoad, Loading, fmtDate, fmtPts, openRider, normName, flag, withFlag } from '../lib.js';
import { labelText } from './results.js';

// Standard: WorldTour (Männer/Frauen), WM, EM
const WT = ['1.UWT', '2.UWT', '1.WWT', '2.WWT'];
const isChampionship = (r) => r.uci_class === 'CM' || (r.uci_class === 'CC' && /europ/i.test(r.name));
const isDefault = (r) => WT.includes(r.uci_class) || isChampionship(r);

const CLASS_GROUPS = [
  ['top', 'WorldTour + WM + EM'], ['wt', 'nur WorldTour'], ['champ', 'Meisterschaften'],
  ['pro', 'ProSeries (.Pro)'], ['1', 'Klasse .1'], ['2', 'Klasse .2'], ['all', 'Alle Rennen'],
];
const matchClass = (r, g) => g === 'all' ? true : g === 'top' ? isDefault(r) : g === 'wt' ? WT.includes(r.uci_class)
  : g === 'champ' ? ['CM', 'CC', 'NC'].includes(r.uci_class) || /champ/i.test(r.name)
  : g === 'pro' ? /\.Pro$/i.test(r.uci_class || '') : (r.uci_class || '').endsWith('.' + g);

const MONTHS = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

export function Races({ c, sub }) {
  const year = new Date().getFullYear();
  const races = useLoad(() => all(() => sb.from('races').select('pcs_slug,name,uci_class,country,start_date,end_date')
    .eq('gender', c.league.gender).not('dataride_id', 'is', null)
    .gte('start_date', `${year}-01-01`).order('start_date', { ascending: false })), [c.league.gender, year]);
  if (sub) return html`<${RaceDetail} c=${c} slug=${decodeURIComponent(sub)} />`;
  if (!races.data) return html`<${Loading} error=${races.error} />`;
  return html`<${RaceList} c=${c} races=${races.data} />`;
}

function RaceList({ c, races }) {
  const today = new Date().toISOString().slice(0, 10);
  const [mode, setMode] = useState('results');      // results | calendar
  const [group, setGroup] = useState('top');
  const [country, setCountry] = useState('');
  const [month, setMonth] = useState('');
  const [term, setTerm] = useState('');
  const countries = useMemo(() => [...new Set(races.map((r) => r.country).filter(Boolean))].sort(), [races]);
  const t = normName(term);
  const byMode = mode === 'calendar'
    ? races.filter((r) => (r.end_date || r.start_date) >= today).sort((a, b) => (a.start_date > b.start_date ? 1 : -1))
    : races.filter((r) => r.start_date <= today);
  const list = byMode.filter((r) => matchClass(r, group) && (!country || r.country === country)
    && (!month || (r.start_date || '').slice(5, 7) === month)
    && (!t || t.split(' ').every((w) => normName(r.name).includes(w))));

  return html`<section class="card">
    <div class="row between"><h2>Rennen</h2>
      <div class="seg small">
        <button class=${mode === 'results' ? 'active' : ''} onClick=${() => setMode('results')}>Ergebnisse</button>
        <button class=${mode === 'calendar' ? 'active' : ''} onClick=${() => setMode('calendar')}>Kalender</button>
      </div></div>
    <p class="muted small">${list.length} von ${byMode.length} Rennen${mode === 'calendar' ? ' · Startlisten liefert die UCI leider nicht' : ''}</p>
    <div class="filters">
      <input type="search" placeholder="Rennen suchen" value=${term} onInput=${(e) => setTerm(e.target.value)} />
      <select value=${group} onChange=${(e) => setGroup(e.target.value)}>${CLASS_GROUPS.map(([k, l]) => html`<option value=${k}>${l}</option>`)}</select>
      <select value=${country} onChange=${(e) => setCountry(e.target.value)}><option value="">Alle Länder</option>${countries.map((x) => html`<option value=${x}>${withFlag(x)}</option>`)}</select>
      <select value=${month} onChange=${(e) => setMonth(e.target.value)}><option value="">Alle Monate</option>
        ${MONTHS.map((m, i) => html`<option value=${String(i + 1).padStart(2, '0')}>${m}</option>`)}</select>
    </div>
    ${races.length === 0 ? html`<p class="muted">Noch keine Rennen geladen – der Abruf „Rennergebnisse laden“ läuft bzw. startet mittwochs.</p>` : html`
    <ul class="list">${list.map((r) => html`<li key=${r.pcs_slug} class=${r.start_date <= today && (r.end_date || r.start_date) >= today ? 'live' : ''}>
      <a class="race-link" href=${`#/league/${c.league.id}/races/${encodeURIComponent(r.pcs_slug)}`}>
        <strong>${r.name}</strong>
        <span class="muted small">${fmtDate(r.start_date)}${r.end_date && r.end_date !== r.start_date ? ` – ${fmtDate(r.end_date)}` : ''}${r.country ? ` · ${withFlag(r.country)}` : ''}</span>
      </a>
      <span class="row">${r.start_date <= today && (r.end_date || r.start_date) >= today ? html`<span class="tag ok">läuft</span>` : ''}<span class="tag">${r.uci_class}</span></span></li>`)}</ul>`}
  </section>`;
}

function RaceDetail({ c, slug }) {
  const data = useLoad(async () => {
    const [race] = await q(sb.from('races').select('*').eq('pcs_slug', slug));
    const events = await q(sb.from('race_events').select('*').eq('race_slug', slug).order('stage_no').order('id'));
    return { race, events };
  }, [slug]);
  const [eventId, setEventId] = useState(null);
  if (!data.data) return html`<${Loading} error=${data.error} />`;
  const { race, events } = data.data;
  // Etappen (stage_name) mit ihren Wertungen
  const stages = [];
  for (const e of events) {
    let s = stages.find((x) => x.name === e.stage_name);
    if (!s) stages.push(s = { name: e.stage_name, date: e.event_date, events: [] });
    s.events.push(e);
  }
  stages.forEach((s) => s.events.sort((a, b) => eventOrder(a.event_name) - eventOrder(b.event_name)));
  const preferred = (s) => s.events.find((e) => /^(Stage )?Classification$|Final Classification|^General Classification$/.test(e.event_name)
    && !/Points|Mountain|Youth|Team/.test(e.event_name)) || s.events[0];
  // Standard: Schlusswertung (bzw. letzte Etappe), sonst das Ergebnis des Eintagesrennens
  const current = events.find((e) => e.id === eventId) || (stages.length ? preferred(stages[stages.length - 1]) : null);

  return html`<div class="stack">
    <a href=${`#/league/${c.league.id}/races`} class="muted small-link">← Alle Rennen</a>
    <section class="card">
      <div class="row between"><h2>${race?.name}</h2><span class="tag">${race?.uci_class}</span></div>
      <p class="muted small">${fmtDate(race?.start_date)}${race?.end_date !== race?.start_date ? ` – ${fmtDate(race?.end_date)}` : ''}${race?.country ? ` · ${withFlag(race.country)}` : ''}</p>
      ${stages.length > 1 && html`<label class="inline">Etappe
        <select value=${current ? stages.findIndex((s) => s.events.includes(current)) : 0}
          onChange=${(e) => setEventId(preferred(stages[+e.target.value]).id)}>
          ${stages.map((s, i) => html`<option value=${i}>${/final/i.test(s.name || '') ? 'GC' : labelText(s.name || '')}${s.date ? ` · ${fmtDate(s.date)}` : ''}</option>`)}
        </select></label>`}
      ${current && html`<div class="seg small wrap-seg">${stages.find((s) => s.events.includes(current)).events.map((e) =>
        html`<button class=${e.id === current.id ? 'active' : ''} onClick=${() => setEventId(e.id)}>${eventLabel(e.event_name)}</button>`)}</div>`}
    </section>
    ${current ? html`<${ResultTable} c=${c} event=${current} />`
      : html`<p class="muted card">${race?.start_date > new Date().toISOString().slice(0, 10)
        ? 'Das Rennen hat noch nicht stattgefunden. Ergebnisse erscheinen nach dem nächsten Abruf (mittwochs).'
        : 'Noch keine Ergebnisse geladen.'}</p>`}
  </div>`;
}

// Wertungsnamen der UCI → kurze deutsche Bezeichnung (ganzer Name wird ersetzt, kein "Stage …"-Rest)
const EVENT_LABELS = [
  [/^Stage Classification$|^Stage Result$/i, 'Etappe', 0],
  [/General Classification/i, 'GC', 1],
  [/^Final Classification$|^Result$/i, 'Ergebnis', 0],
  [/Points Classification|Sprint/i, 'Punkte', 2],
  [/Mountains? Classification|Climber|KOM/i, 'Berg', 3],
  [/Youth|Young Riders?|Best Young/i, 'Nachwuchs', 4],
  [/Team/i, 'Team', 5],
];
const eventLabel = (n) => {
  const hit = EVENT_LABELS.find(([re]) => re.test(n || ''));
  return hit ? hit[1] : (n || '').replace(/^(Stage|Overall)\s+/i, '').replace(/\s+Classification$/i, '') || n;
};
const eventOrder = (n) => (EVENT_LABELS.find(([re]) => re.test(n || ''))?.[2] ?? 9);

function ResultTable({ c, event }) {
  const rows = useLoad(() => q(sb.from('event_results').select('*').eq('event_id', event.id).order('sort_order')), [event.id]);
  if (!rows.data) return html`<${Loading} error=${rows.error} />`;
  return html`<section class="card"><div class="scroll-x"><table class="tbl">
    <thead><tr><th class="num">Rang</th><th>Fahrer</th><th class="hide-sm">Team</th><th class="num">Zeit</th><th class="num">Pkt.</th><th class="hide-sm">Kader</th></tr></thead>
    <tbody>${rows.data.map((r) => {
      const m = r.rider_slug && c.managerMap[c.owner[r.rider_slug]];
      return html`<tr key=${r.sort_order} class=${m && m.id === c.me?.id ? 'me' : ''}>
        <td class="num">${r.rank_text || r.rank || ''}</td>
        <td>${r.rider_slug ? html`<button class="linkish" onClick=${() => openRider(r.rider_slug)}>${r.rider_name}</button>` : r.rider_name}
          ${r.nation ? html` <span class="muted small" title=${r.nation}>${flag(r.nation) || r.nation}</span>` : ''}</td>
        <td class="small hide-sm">${r.team || ''}</td>
        <td class="num">${r.result || ''}</td>
        <td class="num">${r.uci_points ? html`<strong>${fmtPts(r.uci_points)}</strong>` : ''}</td>
        <td class="small hide-sm">${m ? m.team_name : ''}</td></tr>`;
    })}</tbody></table></div>
    ${rows.data.length === 0 && html`<p class="muted">Keine Ergebnisse.</p>`}
    <p class="muted small">Top 25 und alle weiteren Plätze mit UCI-Punkten. Quelle: UCI DataRide.</p>
  </section>`;
}
