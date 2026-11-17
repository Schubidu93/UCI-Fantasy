// Liga-Einstellungen im Radsport: Startwerte, eigene Felder (Grenze pro Profiteam, wertende Fahrer), zusätzliche gespeicherte Werte.
import { html } from '../vendor/preact-htm.js';

/** Startwerte beim Anlegen einer Liga (zusätzlich zu den gemeinsamen) */
export const LEAGUE_DEFAULTS = {
  roster_size: 15, scoring_mode: 'full', lineup_size: 9, max_per_team: '', draft_mode: 'live', bid_seconds: 15, gender: 'men',
};
export const SEASON_END = '10-31';
export const GENDER_OPTIONS = [['men', 'Männer Elite'], ['women', 'Frauen Elite']];
export const genderLabel = (g) => (g === 'women' ? 'Frauen' : 'Männer');
export const DRAFT_MODE_ORDER = ['live', 'blind', 'snake', 'offline'];

/** Wert ändern: beim Wechsel auf Snake- oder Blind-Draft eine sinnvolle Zeit vorschlagen */
export const adjustSettings = (f, k, v) => ({ ...f, [k]: v,
  ...(k === 'draft_mode' && v === 'snake' && +f.bid_seconds === 15 ? { bid_seconds: 60 } : {}),
  ...(k === 'draft_mode' && v === 'blind' && +f.bid_seconds === 15 ? { bid_seconds: 20 } : {}) });

/** Formularwerte aus der gespeicherten Liga (Admin → Einstellungen) */
export const settingsInit = (l) => ({ ...l, max_per_team: l.max_per_team ?? '', lineup_size: l.lineup_size ?? Math.min(9, l.roster_size) });

/** Zusätzliche Werte für create_league / update_league_settings (wertende Fahrer immer, Profiteam-Grenze nur vor dem Draft) */
export const settingsPayload = (f, { locked = false } = {}) => ({
  lineup_size: f.scoring_mode === 'lineup' ? +f.lineup_size : null,
  ...(locked ? {} : { max_per_team: f.max_per_team ? +f.max_per_team : null }),
});

/** Felder zwischen „Anzahl Mitspieler“ und „Draft-Modus“: Kadergröße, Profiteam-Grenze, Wertung */
export const SquadFields = ({ f, set, locked }) => html`
    <label>Fahrer pro Team (5–30)<input type="number" min="5" max="30" value=${f.roster_size} onInput=${set('roster_size')} disabled=${locked} /></label>
    <label>Max. Fahrer pro Profiteam<input type="number" min="1" placeholder="keine Grenze" value=${f.max_per_team ?? ''} onInput=${set('max_per_team')} disabled=${locked} /></label>
    <label>Wertungsmodus
      <select value=${f.scoring_mode} onChange=${set('scoring_mode')}>
        <option value="full">Gesamtkader zählt</option><option value="lineup">Aufstellung pro Spieltag</option>
      </select></label>
    ${f.scoring_mode === 'lineup' && html`<label>Wertende Fahrer<input type="number" min="1" max=${f.roster_size} value=${f.lineup_size ?? ''} onInput=${set('lineup_size')} /></label>`}`;
