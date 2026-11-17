// Personenauswahl mit Suche (Draft, Offline-Draft, Korrekturen): Name oder Gruppe/Team, z. B. „1500“ oder „UAE“
import { html, useState } from '../vendor/preact-htm.js';
import { normName } from '../lib.js';
import { pid, RiderCell, searchText, SPORT } from '../sport/index.js';

export function RiderPicker({ people, onPick, placeholder = `${SPORT.one} suchen …`, limit = 30, action = 'Wählen' }) {
  const [term, setTerm] = useState('');
  const t = normName(term);
  const list = people.filter((r) => !t || t.split(' ').every((w) => searchText(r).includes(w))).slice(0, limit);
  return html`<div class="picker">
    <input type="search" placeholder=${placeholder} value=${term} onInput=${(e) => setTerm(e.target.value)} />
    <ul class="list">
      ${list.map((r) => html`<li key=${pid(r)}>
        <${RiderCell} r=${r} />
        <button class="small" onClick=${() => onPick(r)}>${action}</button>
      </li>`)}
      ${list.length === 0 ? html`<li class="muted">Keine Treffer</li>` : ''}
    </ul>
  </div>`;
}
