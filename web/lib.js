// Gemeinsame Helfer: Supabase-Zugang, Datenabruf, Formatierung
import { html, useState, useEffect, useCallback, useRef } from './vendor/preact-htm.js';
import cfg from './config.js';

export const sb = window.supabase.createClient(cfg.url, cfg.anonKey);

export async function rpc(fn, args = {}) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

export async function q(builder) {
  const { data, error } = await builder;
  if (error) throw new Error(error.message);
  return data;
}

// Alle Zeilen holen (Supabase liefert max. 1000 pro Abfrage)
export async function all(makeQuery) {
  const out = [];
  for (let from = 0; ; from += 1000) {
    const rows = await q(makeQuery().range(from, from + 999));
    out.push(...rows);
    if (rows.length < 1000) return out;
  }
}

// ---- Formatierung --------------------------------------------------------

export const fmtDate = (d) => (d ? new Date(d.length === 10 ? d + 'T00:00:00' : d).toLocaleDateString('de-DE') : '–');
export const fmtDateTime = (d) =>
  d ? new Date(d).toLocaleString('de-DE', { dateStyle: 'short', timeStyle: 'short' }) : '–';
export const fmtPts = (n) => (Math.round((Number(n) || 0) * 10) / 10).toLocaleString('de-DE');
export const today = () => new Date().toISOString().slice(0, 10);

export function riderName(r) {
  if (!r) return '?';
  return r.name;
}

// Namen vergleichbar machen: "POGAČAR Tadej" == "tadej pogacar"
export function normName(s) {
  return (s || '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9 ]/g, ' ')
    .split(/\s+/).filter(Boolean).sort().join(' ');
}

export const SOURCE_LABEL = { draft: 'Draft', offline: 'Offline-Draft', waiver: 'Waiver', trade: 'Tausch', admin: 'Admin' };

// ---- Hooks ---------------------------------------------------------------

// Lädt Daten und bietet reload(); zeigt Fehler an
export function useLoad(fn, deps) {
  const [state, setState] = useState({ data: null, error: null, loading: true });
  const seq = useRef(0);
  const load = useCallback(async () => {
    const n = ++seq.current;
    try {
      const data = await fn();
      if (n === seq.current) setState({ data, error: null, loading: false });
    } catch (e) {
      if (n === seq.current) setState((s) => ({ ...s, error: e.message, loading: false }));
    }
  }, deps);
  useEffect(() => { load(); }, [load]);
  return { ...state, reload: load };
}

// Führt eine Aktion aus und zeigt Fehler/Erfolg
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const run = async (fn, okText) => {
    setBusy(true); setMsg(null);
    try {
      const r = await fn();
      if (okText) setMsg({ ok: true, text: okText });
      return r;
    } catch (e) {
      setMsg({ ok: false, text: e.message });
    } finally {
      setBusy(false);
    }
  };
  return { busy, msg, run, setMsg };
}

// ---- kleine Bausteine ----------------------------------------------------

export const Msg = ({ msg }) =>
  msg ? html`<p class=${msg.ok ? 'note ok' : 'note err'} role="status">${msg.text}</p>` : null;

export const Loading = ({ error }) =>
  error ? html`<p class="note err">${error}</p>` : html`<p class="muted">Lädt …</p>`;

// Fahrer-Fenster öffnen (Ergebnisse und Punkte der Saison), siehe views/rider.js
export const openRider = (slug) => dispatchEvent(new CustomEvent('rider:open', { detail: slug }));

export function RiderCell({ r }) {
  if (!r) return html`<span class="muted">unbekannt</span>`;
  return html`<span class="rider">
    <button type="button" class="rider-name linkish" title="Ergebnisse anzeigen"
      onClick=${(e) => { e.stopPropagation(); openRider(r.pcs_slug); }}>${r.name}</button>${r.inactive ? html` <span class="tag warn">inaktiv</span>` : ''}
    <span class="rider-meta">${[r.team, r.nation, r.uci_rank && `UCI #${r.uci_rank}`].filter(Boolean).join(' · ')}</span>
  </span>`;
}

// Fahrerauswahl mit Suche
export function RiderPicker({ riders, onPick, placeholder = 'Fahrer suchen …', limit = 30, action = 'Wählen' }) {
  const [term, setTerm] = useState('');
  const t = normName(term);
  const list = riders
    .filter((r) => !t || normName(r.name + ' ' + (r.team || '')).includes(t) || t.split(' ').every((w) => normName(r.name + ' ' + (r.team || '')).includes(w)))
    .slice(0, limit);
  return html`<div class="picker">
    <input type="search" placeholder=${placeholder} value=${term} onInput=${(e) => setTerm(e.target.value)} />
    <ul class="list">
      ${list.map((r) => html`<li key=${r.pcs_slug}>
        <${RiderCell} r=${r} />
        <button class="small" onClick=${() => onPick(r)}>${action}</button>
      </li>`)}
      ${list.length === 0 ? html`<li class="muted">Keine Treffer</li>` : ''}
    </ul>
  </div>`;
}
