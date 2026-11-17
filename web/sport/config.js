// Sportart Radsport: alles, worin sich UCI Fantasy von Runner Fantasy unterscheidet (Begriffe,
// Spaltennamen, Texte). Der übrige App-Code ist in beiden Apps gleich und liest diese Werte hier.
// Reine Daten ohne Abhängigkeiten – auch von web/lib.js genutzt.

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
  ptsFormat: { maximumFractionDigits: 1 },   // Anzeige der Punkte
  pointsRpc: 'rider_points',
  // Texte
  dataLine: 'Daten: UCI (DataRide, Wettkampfverzeichnis). Keine offizielle App der UCI.',
  matchdayExamples: 'Klassiker, Giro, Tour, Vuelta',   // Beispiele für Spieltage
  fallbackBasis: 'UCI-Ranglistenpunkte', fallbackShort: 'Rangl.',   // Draft-Report ohne Vorjahrespunkte
  rankingOption: 'nach UCI-Rangliste', rankingPhrase: 'nach UCI-Rangliste',   // Draft-Reihenfolge
  bestBy: 'nach UCI-Rang', orderLabel: 'UCI-Rangliste',   // Draft: automatische Wahl, Reihenfolge
  csvNameHint: 'Fahrername wie in der UCI-Rangliste, z. B. „POGAČAR Tadej“', inPoolWord: 'im Ranking',   // Offline-Draft (CSV)
  resultsSchedule: 'Rennergebnisse kommen täglich um 20 Uhr.',
};
/** Schlüssel einer Person (Athlet bzw. Fahrer) */
export const pid = (r) => r?.pcs_slug;

/** Platz der Person in der Auswahl (UCI-Rang) – für Sortierungen */
export const rank = (r) => r?.uci_rank;
/** Darf geholt werden (Waiver, Draft): alle Fahrer der Liga */
export const selectable = () => true;
