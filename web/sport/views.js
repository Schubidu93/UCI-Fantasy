// Sportart Radsport: eigene Seiten, Navigation und Laden der Fahrer (von app.js eingebunden).
import { Riders } from './riders.js';
import { Races } from './races.js';
import { TopResults } from './top.js';
import { all, sb } from '../lib.js';

/** Alle Fahrer der Liga, sortiert nach UCI-Rang */
export const loadPeople = (league) => all(() => sb.from('athletes').select('*').eq('gender', league.gender)
  .order('pool_rank', { nullsFirst: false }).order('id'));

/** Bereiche der Navigation für Personen und Rennen */
export const SPORT_SECTIONS = [
  { key: 'people', route: 'riders', label: 'Fahrer', tabs: [['riders', 'Fahrer']] },
  { key: 'races', label: 'Rennen', tabs: [['races', 'Rennen'], ['top', 'Top-Ergebnisse']] },
];
export const SPORT_VIEWS = { riders: Riders, races: Races, top: TopResults };
export const PEOPLE_ICON = '<circle cx="5.5" cy="17.5" r="3.5"/><circle cx="18.5" cy="17.5" r="3.5"/><circle cx="15" cy="5" r="1"/><path d="M12 17.5V14l-3-3 4-3 2 3h2"/>';

