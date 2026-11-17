// Sportart Radsport: alles, worin sich UCI Fantasy von Runner Fantasy unterscheidet (Begriffe,
// Spaltennamen, Texte). Der übrige App-Code ist in beiden Apps gleich und liest diese Werte hier.
import { html } from '../vendor/preact-htm.js';
import { teamName } from '../lib.js';

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
  pointsRpc: 'rider_points',
  // Texte
  dataLine: 'Daten: UCI (DataRide, Wettkampfverzeichnis). Keine offizielle App der UCI.',
  resultsSchedule: 'Rennergebnisse kommen täglich um 20 Uhr.',
};
/** Schlüssel einer Person (Athlet bzw. Fahrer) */
export const pid = (r) => r?.pcs_slug;

/** Zeile unter dem Namen in Listen (Teampunkte): Sportart-Info und Zusatztext */
export const PersonLine = ({ r, sub }) => html`${[r?.team && teamName(r.team), sub].filter(Boolean).join(' · ')}`;
