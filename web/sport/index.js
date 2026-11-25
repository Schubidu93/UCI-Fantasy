// Sportart Radsport: alles, worin sich UCI Fantasy von Athletics Fantasy unterscheidet (Begriffe,
// Spaltennamen, Texte). Der übrige App-Code ist in beiden Apps gleich und liest diese Werte hier.
import { html, useState } from '../vendor/preact-htm.js';
export * from './config.js';
import { SPORT, pid } from './config.js';
import { normName, openRider, SearchSelect, teamName, withFlag } from '../lib.js';


/** Zeile unter dem Namen in Listen (Teampunkte): Sportart-Info und Zusatztext */
export const PersonLine = ({ r, sub }) => html`${[r?.team && teamName(r.team), sub].filter(Boolean).join(' · ')}`;


/** Filter für Personenlisten (freie Fahrer): Profiteam und Nation. Liefert [Eingaben, Prüfung]. */
export function usePeopleFilter(c, list) {
  const [team, setTeam] = useState('');
  const [nation, setNation] = useState('');
  const teams = [...new Set(list.map((r) => r.team).filter(Boolean))].sort();
  const nations = [...new Set(list.map((r) => r.nation).filter(Boolean))].sort();
  const ui = html`<${SearchSelect} value=${team} onChange=${setTeam} options=${teams} label=${teamName} placeholder="Team (z. B. UAE)" />
      <select value=${nation} onChange=${(e) => setNation(e.target.value)}><option value="">Alle Nationen</option>${nations.map((x) => html`<option value=${x}>${withFlag(x)}</option>`)}</select>`;
  return [ui, (r) => (!team || normName(team).split(' ').every((w) => normName(r.team || '').includes(w))) && (!nation || r.nation === nation)];
}

// Bezeichnung eines gewerteten Ergebnisses: Etappe, Gesamt-, Berg-, Punktewertung …
const LABELS = [
  [/^Final Classification · General Classification$/, 'Gesamtwertung'],
  [/^Final Classification$/, 'Ergebnis'],
  [/^Final Classification · /, ''],
  [/^Stage (\d+) · Stage Classification$/, 'Etappe $1'],
  [/^Stage (\d+) · Stage General Classification$/, 'Etappe $1 · Gesamtführung'],
  [/^Prologue · Stage Classification$/, 'Prolog'],
  [/^Prologue · Stage General Classification$/, 'Prolog · Gesamtführung'],
  [/General Classification/g, 'Gesamtwertung'], [/Mountains? Classification/g, 'Bergwertung'],
  [/Points Classification/g, 'Punktewertung'], [/Young Riders? Classification/g, 'Nachwuchswertung'],
  [/^Stage (\d+)/, 'Etappe $1'], [/^Prologue/, 'Prolog'],
];
export const labelText = (l) => {
  if (!l || l === 'result') return 'Ergebnis';
  return LABELS.reduce((t, [re, rep]) => t.replace(re, rep), l);
};

/** Name mit Kurzinfo (Gruppe/Jahrgang bzw. Nation/Team), antippen öffnet das Profil */
/** Zusatz zu einem Kader-Fahrer in der Liga-Übersicht: Punkte im laufenden Jahr */
// Punkte im Jahr rechts neben dem Namen: ganze Zahl, darunter klein das Jahr
export const RosterNote = ({ pts, year }) => html`<span class="roster-pts"><strong>${Math.round(pts || 0).toLocaleString('de-DE')}</strong><small>${year}</small></span>`;

export function RiderCell({ r }) {
  if (!r) return html`<span class="muted">unbekannt</span>`;
  const meta = [r.nation && withFlag(r.nation), r.birth_date && r.birth_date.slice(0, 4)].filter(Boolean).join(' · ');
  return html`<span class="rider">
    <span class="rider-line">
      <button type="button" class="rider-name linkish" title="Ergebnisse anzeigen"
        onClick=${(e) => { e.stopPropagation(); openRider(r.id); }}>${r.name}</button>
      ${r.pool_rank && html`<span class="rank-chip" title="Platz im UCI-Ranking">#${r.pool_rank}</span>`}
      ${r.inactive && html`<span class="tag warn">inaktiv</span>`}
    </span>
    ${meta && html`<span class="rider-meta">${meta}</span>`}
    ${r.team && html`<span class="rider-team" title=${r.team}>${teamName(r.team)}</span>`}
  </span>`;
}

/** Suchtext für die Personenauswahl (Name plus Disziplingruppe bzw. Team) */
export const searchText = (r) => normName(r.name + ' ' + (r.team || ''));
