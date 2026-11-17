// Sportart Radsport: alles, worin sich UCI Fantasy von Runner Fantasy unterscheidet (Begriffe,
// Spaltennamen, Texte). Der übrige App-Code ist in beiden Apps gleich und liest diese Werte hier.
import { html, useState } from '../vendor/preact-htm.js';
import { teamName, SearchSelect, withFlag, normName } from '../lib.js';

export const SPORT = {
  app: 'UCI Fantasy', emoji: '🚴', source: 'UCI DataRide',
  // Begriffe in den gebrauchten Fällen: ein Fahrer, einen Fahrer, die Fahrer, den Fahrern (Dativ Plural), des Fahrers
  one: 'Fahrer', oneAcc: 'Fahrer', many: 'Fahrer', manyDat: 'Fahrern', oneGen: 'Fahrers',
  // Spaltennamen in der Datenbank (historische Namen aus der Anfangszeit, siehe CLAUDE.md)
  pk: 'pcs_slug',             // Schlüssel der Personentabelle
  fk: 'rider_slug',           // Verweis darauf (Kader, Aufstellung, Ergebnisse …)
  add: 'add_rider', drop: 'drop_rider',              // Waiver-Anträge
  give: 'give_riders', take: 'take_riders',          // Tausch
  current: 'current_rider',                          // Draft: aktuell versteigert
  comp: 'race_slug', pts: 'uci_points',              // Ergebnisse
  pointsWord: 'UCI-Punkten',                       // „Sortiert nach …“
  pointsRpc: 'rider_points',
  // Texte
  dataLine: 'Daten: UCI (DataRide, Wettkampfverzeichnis). Keine offizielle App der UCI.',
  matchdayExamples: 'Klassiker, Giro, Tour, Vuelta',   // Beispiele für Spieltage
  fallbackBasis: 'UCI-Ranglistenpunkte', fallbackShort: 'Rangl.',   // Draft-Report ohne Vorjahrespunkte
  resultsSchedule: 'Rennergebnisse kommen täglich um 20 Uhr.',
};
/** Schlüssel einer Person (Athlet bzw. Fahrer) */
export const pid = (r) => r?.pcs_slug;

/** Zeile unter dem Namen in Listen (Teampunkte): Sportart-Info und Zusatztext */
export const PersonLine = ({ r, sub }) => html`${[r?.team && teamName(r.team), sub].filter(Boolean).join(' · ')}`;

/** Platz der Person in der Auswahl (UCI-Rang) – für Sortierungen */
export const rank = (r) => r?.uci_rank;
/** Darf geholt werden (Waiver, Draft): alle Fahrer der Liga */
export const selectable = () => true;

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
