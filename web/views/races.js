// Rennen der Saison mit Ergebnislisten (Rang, Fahrer, Team, Zeit, UCI-Punkte)
import { html, useState, useMemo } from '../vendor/preact-htm.js';
import { sb, q, all, useLoad, Loading, fmtDate, fmtPts, openRider, normName, flag, withFlag, nationCode } from '../lib.js';
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

// Rennklassen mit vollständigen Ergebnislisten (siehe datasync/race_results.py)
const FULL = ['1.UWT', '2.UWT', '1.WWT', '2.WWT', '1.Pro', '2.Pro', 'CM'];

// Letzter bereits gefahrener Tag eines Rennens (laufende Rundfahrt: heute)
const latestDay = (r, today) => { const e = r.end_date || r.start_date; return e > today ? today : e; };

// Rennen läuft (zumindest teilweise) im Monat ym = 'JJJJ-MM'
const overlapsMonth = (r, ym) => (r.start_date || '').slice(0, 7) <= ym && (r.end_date || r.start_date || '').slice(0, 7) >= ym;

const MONTHS = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

export function Races({ c, sub, sub2 }) {
  // Ergebnisse gibt es ab der Saison 2025
  const races = useLoad(() => all(() => sb.from('races').select('pcs_slug,name,uci_class,country,start_date,end_date,provisional')
    .eq('gender', c.league.gender).or('dataride_id.not.is.null,provisional.is.true')
    .gte('start_date', '2025-01-01').order('start_date', { ascending: false })), [c.league.gender]);
  if (sub) return html`<${RaceDetail} key=${sub + (sub2 || '')} c=${c} slug=${decodeURIComponent(sub)} initialEvent=${sub2 ? +sub2 : null} />`;
  if (!races.data) return html`<${Loading} error=${races.error} />`;
  return html`<${RaceList} c=${c} races=${races.data.map((r) => ({ ...r, country: r.country && nationCode(r.country) }))} />`;
}

// Filter bleiben beim Zurückkehren aus einem Rennen erhalten
// year 'auto': Ergebnisse = aktuelles Jahr, Kalender = alle Jahre
const saved = { mode: 'results', group: 'top', country: '', month: '', term: '', year: 'auto', md: '' };
const keep = (key, setter) => (v) => { saved[key] = v; setter(v); };

function RaceList({ c, races }) {
  const today = new Date().toISOString().slice(0, 10);
  const [mode, setModeRaw] = useState(saved.mode);      // results | calendar
  const [group, setGroupRaw] = useState(saved.group);
  const [country, setCountryRaw] = useState(saved.country);
  const [month, setMonthRaw] = useState(saved.month);
  const [term, setTermRaw] = useState(saved.term);
  const setMode = keep('mode', setModeRaw), setGroup = keep('group', setGroupRaw), setCountry = keep('country', setCountryRaw);
  const [yearSel, setYearRaw] = useState(saved.year);
  const [mdId, setMdRaw] = useState(saved.md);
  const setMonth = keep('month', setMonthRaw), setTerm = keep('term', setTermRaw), setYear = keep('year', setYearRaw);
  const setMd = (v) => { keep('md', setMdRaw)(v); if (v) setYear(''); };
  const years = useMemo(() => [...new Set(races.map((r) => (r.start_date || '').slice(0, 4)).filter(Boolean))].sort().reverse(), [races]);
  const year = yearSel === 'auto' ? (mode === 'results' ? today.slice(0, 4) : '') : yearSel;
  const matchdays = c.matchdays || [];
  const md = matchdays.find((m) => m.id === mdId);
  const countries = useMemo(() => [...new Set(races.map((r) => r.country).filter(Boolean))].sort(), [races]);
  const t = normName(term);
  const byMode = mode === 'calendar'
    ? races.filter((r) => (r.end_date || r.start_date) >= today).sort((a, b) => (a.start_date > b.start_date ? 1 : -1))
    // Ergebnisse: neueste zuerst nach letztem gefahrenen Tag (laufende Rundfahrt = heute, sonst letzte Etappe)
    : races.filter((r) => r.start_date <= today).sort((a, b) => {
      const la = latestDay(a, today), lb = latestDay(b, today);
      return la !== lb ? (la < lb ? 1 : -1) : (a.start_date < b.start_date ? 1 : -1);
    });
  const list = byMode.filter((r) => matchClass(r, group) && (!country || r.country === country)
    && (!year || (month ? overlapsMonth(r, `${year}-${month}`)
      : (r.start_date || '').slice(0, 4) === year || (r.end_date || '').slice(0, 4) === year))
    && (!md || (r.start_date <= md.ends_on && (r.end_date || r.start_date) >= md.starts_on))
    && (!t || t.split(' ').every((w) => normName(r.name).includes(w))));

  return html`<section class="card">
    <div class="row between"><h2>Rennen</h2>
      <div class="seg small">
        <button class=${mode === 'results' ? 'active' : ''} onClick=${() => setMode('results')}>Ergebnisse</button>
        <button class=${mode === 'calendar' ? 'active' : ''} onClick=${() => setMode('calendar')}>Kalender</button>
      </div></div>
    <p class="muted small">${list.length} von ${byMode.length} Rennen${mode === 'calendar' ? ' · Startlisten liefert die UCI leider nicht' : ''}</p>
    ${mode === 'calendar' && byMode.length < 10 && html`<p class="note small">Die UCI trägt den Rennkalender der nächsten Saison erst nach und nach ein.
      Neue Rennen erscheinen hier automatisch (Abruf täglich um 20 Uhr).</p>`}
    <div class="filters">
      <input type="search" placeholder="Rennen suchen" value=${term} onInput=${(e) => setTerm(e.target.value)} />
      <select value=${group} onChange=${(e) => setGroup(e.target.value)}>${CLASS_GROUPS.map(([k, l]) => html`<option value=${k}>${l}</option>`)}</select>
      <select value=${country} onChange=${(e) => setCountry(e.target.value)}><option value="">Alle Länder</option>${countries.map((x) => html`<option value=${x}>${withFlag(x)}</option>`)}</select>
      <select value=${year} onChange=${(e) => setYear(e.target.value)}><option value="">Alle Jahre</option>
        ${years.map((y) => html`<option value=${y}>${y}</option>`)}</select>
      <select value=${year ? month : ''} disabled=${!year} onChange=${(e) => setMonth(e.target.value)}>
        <option value="">${year ? `Alle Monate ${year}` : 'Monat (erst Jahr wählen)'}</option>
        ${year && MONTHS.map((m, i) => html`<option value=${String(i + 1).padStart(2, '0')}>${m} ${year}</option>`)}</select>
      ${matchdays.length > 0 && html`<select value=${md ? md.id : ''} onChange=${(e) => setMd(e.target.value)}><option value="">Alle Spieltage</option>
        ${matchdays.map((m) => html`<option value=${m.id}>${m.name} (${fmtDate(m.starts_on)} – ${fmtDate(m.ends_on)})</option>`)}</select>`}
    </div>
    ${races.length === 0 ? html`<p class="muted">Noch keine Rennen geladen – der Abruf läuft täglich um 20 Uhr.</p>` : html`
    <ul class="list race-list">${list.map((r) => html`<li key=${r.pcs_slug} class=${r.start_date <= today && (r.end_date || r.start_date) >= today ? 'live' : ''}>
      <a class="race-link" href=${`#/league/${c.league.id}/races/${encodeURIComponent(r.pcs_slug)}`}>
        <strong>${r.name}</strong>
        <span class="muted small">${fmtDate(r.start_date)}${r.end_date && r.end_date !== r.start_date ? ` – ${fmtDate(r.end_date)}` : ''}${r.country ? ` · ${withFlag(r.country)}` : ''}</span>
      </a>
      <span class="race-tags">${r.start_date <= today && (r.end_date || r.start_date) >= today ? html`<span class="tag ok">läuft</span>` : ''}${r.provisional ? html`<span class="tag warn" title="Termin aus dem UCI-Wettkampfverzeichnis – wird ersetzt, sobald die UCI das Rennen in DataRide einträgt">vorläufig</span>` : ''}<span class="tag">${r.uci_class}</span></span></li>`)}</ul>`}
  </section>`;
}

function RaceDetail({ c, slug, initialEvent }) {
  const data = useLoad(async () => {
    const [race] = await q(sb.from('races').select('*').eq('pcs_slug', slug));
    const events = await q(sb.from('race_events').select('*').eq('race_slug', slug).order('stage_no').order('id'));
    // Rennen ohne Elite-Ergebnisliste (z. B. U23): nur die UCI-Punkte, die Elite-Fahrer dort geholt haben
    const points = events.length ? [] : await q(sb.from('results').select('rider_slug,label,result_date,rank,uci_points')
      .eq('race_slug', slug).order('uci_points', { ascending: false }).limit(300));
    return { race, events, points };
  }, [slug]);
  const [eventId, setEventId] = useState(initialEvent);
  if (!data.data) return html`<${Loading} error=${data.error} />`;
  const { race, events, points } = data.data;
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
  const stageEvents = current ? stages.find((s) => s.events.includes(current)).events : [];
  // Eintagesrennen haben kein GC – dort heißt die Wertung „Ergebnis“
  const label = (n) => (/^1\./.test(race?.uci_class || '') && eventLabel(n) === 'GC' ? 'Ergebnis' : eventLabel(n));

  return html`<div class="stack">
    <a href=${`#/league/${c.league.id}/races`} class="muted small-link">← Alle Rennen</a>
    <section class="card">
      <div class="row between"><h2>${race?.name}</h2><span class="tag">${race?.uci_class}</span></div>
      <p class="muted small">${fmtDate(race?.start_date)}${race?.end_date !== race?.start_date ? ` – ${fmtDate(race?.end_date)}` : ''}${race?.country ? ` · ${withFlag(race.country)}` : ''}</p>
      ${stages.length > 1 && html`<label class="inline">Etappe
        <select value=${current ? stages.findIndex((s) => s.events.includes(current)) : 0}
          onChange=${(e) => setEventId(preferred(stages[+e.target.value]).id)}>
          ${stages.map((s, i) => html`<option value=${i}>${stageLabel(s.name)}${s.date ? ` · ${fmtDate(s.date)}` : ''}</option>`)}
        </select></label>`}
      ${current && stageEvents.length > 1 && html`<div class="seg small wrap-seg">${stageEvents.map((e) =>
        html`<button class=${e.id === current.id ? 'active' : ''} onClick=${() => setEventId(e.id)}>${label(e.event_name)}</button>`)}</div>`}
    </section>
    ${current ? html`<${ResultTable} c=${c} event=${current} race=${race} />`
      : points.length ? html`<section class="card">
          <p class="muted small">Für dieses Rennen führt die UCI keine Elite-Ergebnisliste (z. B. U23-Rennen). Hier die UCI-Punkte, die Fahrer dort für die Weltrangliste geholt haben:</p>
          <table class="tbl"><thead><tr><th class="num">Platz</th><th>Fahrer</th><th class="hide-sm">Wertung</th><th class="num">Pkt.</th></tr></thead>
          <tbody>${points.map((p, i) => html`<tr key=${i}><td class="num">${p.rank || ''}</td>
            <td><button class="linkish" onClick=${() => openRider(p.rider_slug)}>${c.riderMap[p.rider_slug]?.name || p.rider_slug}</button></td>
            <td class="small hide-sm">${labelText(p.label)}</td><td class="num"><strong>${fmtPts(p.uci_points)}</strong></td></tr>`)}</tbody></table>
        </section>`
      : html`<p class="muted card">${race?.start_date > new Date().toISOString().slice(0, 10)
        ? 'Das Rennen hat noch nicht stattgefunden. Ergebnisse erscheinen nach dem Rennen beim täglichen Abruf um 20 Uhr.'
        : race?.loaded_at
          ? 'Die UCI hat für dieses Rennen keine Ergebnisliste veröffentlicht.'
          : 'Noch keine Ergebnisse geladen – sie kommen beim nächsten Abruf (täglich 20 Uhr), sobald die UCI sie veröffentlicht hat.'}</p>`}
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
export const eventLabel = (n) => {
  const name = n || '';
  const hit = EVENT_LABELS.find(([re]) => re.test(name));
  if (!hit) return name.replace(/^(Stage|Overall)\s+/i, '').replace(/\s+Classification$/i, '') || name;
  // Tageswertungen einer Etappe (außer Etappe selbst und GC) als "Etappe Berg", "Etappe Punkte" …
  if (/^Stage\b/i.test(name) && !['Etappe', 'GC'].includes(hit[1])) return `Etappe ${hit[1]}`;
  return hit[1];
};
// Etappen-/Renntag-Namen der UCI auf Deutsch (Meisterschaften: Straßenrennen, Einzelzeitfahren …)
export const stageLabel = (name) => {
  const n = name || '';
  if (/final (classification|result)/i.test(n)) return 'GC';
  if (/individual time trial|\bITT\b/i.test(n)) return 'Einzelzeitfahren';
  if (/team time trial|\bTTT\b|mixed relay/i.test(n)) return 'Mannschaftszeitfahren';
  if (/road race/i.test(n)) return 'Straßenrennen';
  return labelText(n);
};

// "Etappe 6", "Etappe 6 · GC", "GC", "Punkte", "Straßenrennen" … für eine Ergebniszeile
export function describeEvent(stage, event) {
  const s = stageLabel(stage), e = eventLabel(event);
  if (s === 'GC') return e === 'Ergebnis' ? 'Ergebnis' : e;
  if (/^Etappe \d+|^Prolog/.test(s)) return e === 'Etappe' ? s : `${s} · ${e.replace(/^Etappe /, '')}`;
  return e === 'Ergebnis' || e === 'GC' ? s : `${s} · ${e}`;
}

const eventOrder = (n) => (EVENT_LABELS.find(([re]) => re.test(n || ''))?.[2] ?? 9);

function ResultTable({ c, event, race }) {
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
    ${rows.data.length === 0 && html`<p class="muted">Für diese Wertung hat die UCI keine Ergebnisliste veröffentlicht.</p>`}
    <p class="muted small">${FULL.includes(race?.uci_class) && !/Points|Mountain|Young|Youth|Team|Sprint|Combativ/i.test(event.event_name || '')
      ? 'Vollständige Ergebnisliste.' : 'Top 25 und alle weiteren Plätze mit UCI-Punkten.'} Quelle: UCI DataRide.</p>
  </section>`;
}
