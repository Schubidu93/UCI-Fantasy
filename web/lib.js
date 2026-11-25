// Gemeinsame Helfer: Supabase-Zugang, Datenabruf, Formatierung
import { html, useState, useEffect, useCallback, useRef } from './vendor/preact-htm.js';
import cfg from './config.js';
import { SPORT } from './sport/config.js';

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

// Funktion mit vielen Ergebniszeilen seitenweise abrufen (die API liefert max. 1000 Zeilen pro Abfrage)
export const rpcAll = (fn, args = {}) => all(() => sb.rpc(fn, args));

// Punkte aller Personen (Athleten bzw. Fahrer) im laufenden Jahr (einmal pro Wertung geladen und zwischengespeichert)
const pointsCache = {};
export function useRiderPoints(gender) {
  const year = new Date().getFullYear();
  const key = `${gender}-${year}`;
  const [map, setMap] = useState(pointsCache[key] || null);
  useEffect(() => {
    if (pointsCache[key]) return;
    rpcAll('athlete_points', { p_gender: gender, p_year: year })
      .then((rows) => { pointsCache[key] = Object.fromEntries(rows.map((r) => [r.athlete_id, Number(r.points)])); setMap(pointsCache[key]); })
      .catch(() => setMap({}));
  }, [key]);
  return map || {};
}

// ---- Formatierung --------------------------------------------------------

// Einheitlich TT.MM.JJ (z. B. 04.07.26)
export const fmtDate = (d) => (d ? new Date(d.length === 10 ? d + 'T00:00:00' : d)
  .toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: '2-digit' }) : '–');
export const fmtDateTime = (d) =>
  d ? new Date(d).toLocaleString('de-DE', { dateStyle: 'short', timeStyle: 'short' }) : '–';
// Punkte im Format der Sportart (Athletics Fantasy: zwei Nachkommastellen, UCI Fantasy: höchstens eine)
export const fmtPts = (n) => (Number(n) || 0).toLocaleString('de-DE', SPORT.ptsFormat);
// Fristende anzeigen: 0:00 Uhr heißt „bis Ende des Vortags“ → nur das Datum des Vortags; sonst Datum mit Uhrzeit
export function fmtUntil(ts, { weekday = false } = {}) {
  if (!ts) return '–';
  const tz = { timeZone: 'Europe/Berlin' };                  // Fristen gelten in deutscher Zeit
  const d = new Date(ts);
  const time = d.toLocaleTimeString('de-DE', { ...tz, hour: '2-digit', minute: '2-digit' });
  const midnight = time === '00:00';
  const day = midnight ? new Date(d.getTime() - 60000) : d;
  const date = day.toLocaleDateString('de-DE', { ...tz, day: '2-digit', month: '2-digit', year: '2-digit', ...(weekday ? { weekday: 'short' } : {}) });
  return midnight ? date : `${date}, ${time} Uhr`;
}
export const today = () => new Date().toISOString().slice(0, 10);

// Namen vergleichbar machen: "POGAČAR Tadej" == "tadej pogacar"
export function normName(s) {
  return (s || '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9 ]/g, ' ')
    .split(/\s+/).filter(Boolean).sort().join(' ');
}

// Budget spielt nur eine Rolle, wenn Personen im Draft etwas kosten (Auktion/Offline) oder Waiver per FAAB laufen
export const draftCosts = (l) => l.draft_mode !== 'snake';
export const budgetRelevant = (l) => draftCosts(l) || l.waiver_mode === 'faab';

export const SOURCE_LABEL = { draft: 'Draft', offline: 'Offline-Draft', waiver: SPORT.waiver, trade: 'Tausch', admin: 'Admin', free: 'Freie Phase' };

// ---- Flaggen ---------------------------------------------------------------
// Personen kommen mit IOC-Codes (SLO, GER, NED …), UCI-Rennen mit ISO-3-Codes (SVN, DEU …).
const ISO2 = {ABW:'AW',AFG:'AF',AGO:'AO',ALB:'AL',ALG:'DZ',AND:'AD',ANG:'AO',ANT:'AG',ARE:'AE',ARG:'AR',ARM:'AM',ARU:'AW',ASA:'AS',ATG:'AG',AUS:'AU',AUT:'AT',AZE:'AZ',BAH:'BS',BAN:'BD',BAR:'BB',BDI:'BI',BEL:'BE',BEN:'BJ',BER:'BM',BFA:'BF',BGD:'BD',BGR:'BG',BHR:'BH',BHS:'BS',BHU:'BT',BIH:'BA',BIZ:'BZ',BLR:'BY',BOL:'BO',BOT:'BW',BRA:'BR',BRB:'BB',BRN:'BH',BRU:'BN',BUL:'BG',BUR:'BF',CAF:'CF',CAM:'KH',CAN:'CA',CAY:'KY',CGO:'CG',CHA:'TD',CHE:'CH',CHI:'CL',CHL:'CL',CHN:'CN',CIV:'CI',CMR:'CM',COD:'CD',COK:'CK',COL:'CO',COM:'KM',CPV:'CV',CRC:'CR',CRI:'CR',CRO:'HR',CUB:'CU',CUW:'CW',CYP:'CY',CZE:'CZ',DEN:'DK',DEU:'DE',DJI:'DJ',DMA:'DM',DNK:'DK',DOM:'DO',DZA:'DZ',ECU:'EC',EGY:'EG',ERI:'ER',ESA:'SV',ESP:'ES',EST:'EE',ETH:'ET',FIJ:'FJ',FIN:'FI',FJI:'FJ',FRA:'FR',FRO:'FO',FSM:'FM',GAB:'GA',GAM:'GM',GBR:'GB',GBS:'GW',GEO:'GE',GEQ:'GQ',GER:'DE',GHA:'GH',GIB:'GI',GLP:'GP',GMB:'GM',GNB:'GW',GRC:'GR',GRE:'GR',GRL:'GL',GRN:'GD',GTM:'GT',GUA:'GT',GUI:'GN',GUM:'GU',GUY:'GY',HAI:'HT',HKG:'HK',HND:'HN',HON:'HN',HRV:'HR',HUN:'HU',IDN:'ID',INA:'ID',IND:'IN',IRI:'IR',IRL:'IE',IRN:'IR',IRQ:'IQ',ISL:'IS',ISR:'IL',ISV:'VI',ITA:'IT',IVB:'VG',JAM:'JM',JOR:'JO',JPN:'JP',KAZ:'KZ',KEN:'KE',KGZ:'KG',KHM:'KH',KIR:'KI',KNA:'KN',KOR:'KR',KOS:'XK',KSA:'SA',KUW:'KW',KWT:'KW',LAO:'LA',LAT:'LV',LBA:'LY',LBN:'LB',LBR:'LR',LBY:'LY',LCA:'LC',LES:'LS',LIE:'LI',LKA:'LK',LSO:'LS',LTU:'LT',LUX:'LU',LVA:'LV',MAC:'MO',MAD:'MG',MAR:'MA',MAS:'MY',MAW:'MW',MCO:'MC',MDA:'MD',MDG:'MG',MDV:'MV',MEX:'MX',MGL:'MN',MHL:'MH',MKD:'MK',MLI:'ML',MLT:'MT',MMR:'MM',MNE:'ME',MNG:'MN',MON:'MC',MOZ:'MZ',MRI:'MU',MRT:'MR',MTN:'MR',MTQ:'MQ',MUS:'MU',MWI:'MW',MYA:'MM',MYS:'MY',NAM:'NA',NCA:'NI',NCL:'NC',NED:'NL',NEP:'NP',NER:'NE',NGA:'NG',NGR:'NG',NIC:'NI',NIG:'NE',NLD:'NL',NOR:'NO',NRU:'NR',NZL:'NZ',OMA:'OM',OMN:'OM',PAK:'PK',PAN:'PA',PAR:'PY',PER:'PE',PHI:'PH',PHL:'PH',PLE:'PS',PLW:'PW',PNG:'PG',POL:'PL',POR:'PT',PRI:'PR',PRK:'KP',PRT:'PT',PRY:'PY',PSE:'PS',PUR:'PR',PYF:'PF',QAT:'QA',REU:'RE',ROU:'RO',RSA:'ZA',RUS:'RU',RWA:'RW',SAM:'WS',SAU:'SA',SDN:'SD',SEN:'SN',SEY:'SC',SGP:'SG',SKN:'KN',SLB:'SB',SLE:'SL',SLO:'SI',SLV:'SV',SMR:'SM',SOL:'SB',SOM:'SO',SRB:'RS',SRI:'LK',SSD:'SS',STP:'ST',SUD:'SD',SUI:'CH',SUR:'SR',SVK:'SK',SVN:'SI',SWE:'SE',SWZ:'SZ',SXM:'SX',SYC:'SC',SYR:'SY',TAN:'TZ',TGA:'TO',THA:'TH',TJK:'TJ',TKM:'TM',TLS:'TL',TOG:'TG',TON:'TO',TPE:'TW',TTO:'TT',TUN:'TN',TUR:'TR',TUV:'TV',TWN:'TW',TZA:'TZ',UAE:'AE',UGA:'UG',UKR:'UA',URU:'UY',URY:'UY',USA:'US',UZB:'UZ',VAN:'VU',VCT:'VC',VEN:'VE',VGB:'VG',VIE:'VN',VIN:'VC',VIR:'VI',VNM:'VN',WSM:'WS',YEM:'YE',ZAF:'ZA',ZAM:'ZM',ZIM:'ZW',ZMB:'ZM',ZWE:'ZW'};
// Einheitlich IOC-Codes anzeigen (Rennen kommen mit ISO-3: DEU → GER, NLD → NED …)
const IOC = {DEU:'GER',NLD:'NED',CHE:'SUI',DNK:'DEN',PRT:'POR',HRV:'CRO',SVN:'SLO',GRC:'GRE',ARE:'UAE',ZAF:'RSA',IRN:'IRI',
  BGR:'BUL',CHL:'CHI',CRI:'CRC',DZA:'ALG',IDN:'INA',KWT:'KUW',LVA:'LAT',MYS:'MAS',MNG:'MGL',NGA:'NGR',PHL:'PHI',PRY:'PAR',
  SAU:'KSA',URY:'URU',VNM:'VIE',SLV:'ESA',GTM:'GUA',HND:'HON',NIC:'NCA',TWN:'TPE',MDG:'MAD',BFA:'BUR',ZWE:'ZIM',ZMB:'ZAM',
  LKA:'SRI',KHM:'CAM',BGD:'BAN',MMR:'MYA',PRI:'PUR',ABW:'ARU',BRB:'BAR',OMN:'OMA',LBY:'LBA',TGO:'TOG',MRT:'MTN',GIN:'GUI',
  SYC:'SEY',VCT:'VIN',KNA:'SKN',GMB:'GAM',BHS:'BAH'};
export const nationCode = (code) => { const c = (code || '').trim().toUpperCase(); return IOC[c] || c; };

export function flag(code) {
  const iso = ISO2[(code || '').trim().toUpperCase()];
  if (!iso) return '';
  return String.fromCodePoint(...[...iso].map((ch) => 0x1f1e6 + ch.charCodeAt(0) - 65));
}
export const withFlag = (code) => (code ? `${flag(code)} ${nationCode(code)}`.trim() : '');
// Länderauswahl (IOC-Codes), Deutschland und Nachbarn zuerst
export const COUNTRY_CODES = (() => {
  const all = [...new Set(Object.keys(ISO2).map((c) => nationCode(c)))].filter((c) => ISO2[c]).sort();
  const top = ['GER', 'AUT', 'SUI', 'NED', 'BEL', 'FRA', 'ITA', 'ESP', 'GBR', 'USA'];
  return [...top, ...all.filter((c) => !top.includes(c))];
})();

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

// Profil einer Person öffnen (Ergebnisse und Punkte der Saison), siehe sport/rider.js
export const openRider = (slug) => dispatchEvent(new CustomEvent('rider:open', { detail: slug }));

// Teamnamen lesbarer: "UAE TEAM EMIRATES XRG" → "UAE Team Emirates XRG" (bekannte Kürzel bleiben groß)
const ACRONYMS = new Set(['UAE', 'XRG', 'CMA', 'CGM', 'EF', 'BMC', 'NSN', 'DSM', 'MBH', 'JCL', 'TDT', 'UNO', 'X', 'BB', 'SD',
  'VF', 'GW', 'TBV', 'KTM', 'TNL', 'AG', 'CCC', 'SPS', 'DMT', 'ABB', 'USA', 'GB', 'II', 'III', 'FDJ', 'ISD']);
export function teamName(t) {
  if (!t || t !== t.toUpperCase()) return t || '';
  return t.replace(/[A-ZÀ-Ý0-9.]+/g, (w) => (ACRONYMS.has(w) || /\d/.test(w) ? w : w[0] + w.slice(1).toLowerCase()));
}

// Suchfeld mit eigener Vorschlagsliste: tippen filtert die Liste, antippen übernimmt den Eintrag
export function SearchSelect({ value, onChange, options, placeholder, label = (x) => x }) {
  const [open, setOpen] = useState(false);
  const t = normName(value);
  const hits = options.filter((o) => !t || t.split(' ').every((w) => normName(label(o) + ' ' + o).includes(w))).slice(0, 30);
  return html`<div class="search-select">
    <input type="search" placeholder=${placeholder} value=${value} autocomplete="off" autocorrect="off" spellcheck="false"
      onInput=${(e) => { onChange(e.target.value); setOpen(true); }} onFocus=${() => setOpen(true)}
      onBlur=${() => setTimeout(() => setOpen(false), 150)} />
    ${open && hits.length > 0 && html`<ul class="search-select-list">${hits.map((o) => html`<li key=${o}
      onMouseDown=${(e) => { e.preventDefault(); onChange(label(o)); setOpen(false); }}>${label(o)}</li>`)}</ul>`}
  </div>`;
}

/** Kaderplätze als Kacheln (Draft): rows = [{ key, label, name, extra }]; offene Plätze (ohne name) hervorgehoben */
export function SlotTiles({ rows }) {
  const open = rows.filter((x) => !x.name).length;
  return html`<p class="muted small">${open > 0 ? `Noch ${open} von ${rows.length} Plätzen offen.` : 'Kader komplett.'}</p>
    <ul class="list draft-roster">${rows.map((x) => html`<li key=${x.key} class=${x.name ? '' : 'slot-open'}>
      <span class="slot-name">${x.label}</span><span>${x.name || 'offen'}${x.extra ? html` <span class="muted">${x.extra}</span>` : ''}</span></li>`)}</ul>`;
}

// ---------------------------------------------------------------------------------------------------------------------
// Übersetzung der Oberfläche: Die App ist auf Deutsch geschrieben. Für eine andere Sprache (z. B. Niederländisch in
// niederländischen Ligen) meldet die Sportart-Schicht ein Wörterbuch an (registerTexts); setLang schaltet um. Übersetzt wird
// die fertige Seite: je Element der zusammenhängende Text (alle Textstücke zwischen zwei Tags, also ganze Sätze samt
// eingesetzter Werte), dazu placeholder/title/aria-label. Schlüssel im Wörterbuch: der deutsche Text mit {} für eingesetzte
// Werte; in der Übersetzung stehen sie als {0}, {1} … (selbst wieder übersetzt). Ohne Wörterbuch bleibt alles deutsch (UCI Fantasy).
const DICT = {};   // Sprache → { exact: Map, templates: [{ re, chunk, out, size }], patterns: [[RegExp, Ersatz]] }
let LANG = 'de';
let observer = null;
const squash = (s) => s.replace(/\s+/g, ' ').trim();
const escRe = (s) => s.replace(/[.*+?^$()|[\]\\{}]/g, '\\$&');
export const lang = () => LANG;
export function registerTexts(language, texts = {}, patterns = []) {
  const d = DICT[language] ||= { exact: new Map(), templates: [], patterns: [] };
  for (const [k, out] of Object.entries(texts)) {
    const key = squash(k);
    if (!key.includes('{}')) { d.exact.set(key, out); continue; }
    // Leerraum neben eingesetzten Werten darf fehlen (htm entfernt Zeilenumbrüche an diesen Stellen)
    const parts = key.split('{}');
    const part = (x) => (x && !x.trim() ? '\\s+' : escRe(x).replace(/^ +| +$/g, '\\s*'));
    d.templates.push({ re: new RegExp(`^${parts.map(part).join('([\\s\\S]*?)')}$`), out,
      chunk: parts.reduce((a, b) => (b.length > a.length ? b : a), '').trim(), size: parts.join('').length });
  }
  d.templates.sort((a, b) => b.size - a.size);   // genauere Vorlagen zuerst
  d.patterns.push(...patterns);
}
/** Übersetzung aus dem Wörterbuch (genau, Vorlage oder Muster), sonst null */
function lookup(d, key) {
  let out = d.exact.get(key);
  if (out == null) {
    for (const t of d.templates) {
      if (!key.includes(t.chunk)) continue;
      const m = t.re.exec(key);
      // kurze Vorlagen („{} ab {}“) nicht auf lange Sätze anwenden
      if (!m || m.slice(1).join('').length > Math.max(40, 3 * t.size)) continue;
      const vals = m.slice(1).map((v) => tr(v));
      out = typeof t.out === 'function' ? t.out(...vals) : t.out.replace(/\{(\d)\}/g, (_, i) => vals[i]);
      break;
    }
  }
  if (out == null) for (const [re, rep] of d.patterns) if (re.test(key)) { out = key.replace(re, rep); break; }
  return out ?? null;
}
/** Einen Text übersetzen (Leerraum am Rand bleibt); unbekannte Texte bleiben deutsch */
export function tr(s, split = true) {
  const d = DICT[LANG];
  if (!d || !s) return s;
  const key = squash(s);
  if (!key) return s;
  let out = lookup(d, key);
  // zusammengesetzte Zeilen („Mittelstrecke · Jg. 1994“, „Halbfinale 2“): Teile einzeln übersetzen
  if (out == null && split) {
    const sentences = key.split(/(?<=[.!?…]) (?=[A-ZÄÖÜ„(])/);   // aneinandergehängte Sätze (z. B. Draft-Report)
    const t = sentences.length > 1 ? sentences.map((x) => tr(x)) : [];
    if (t.some((x, i) => x !== sentences[i])) out = t.join(' ');
  }
  if (out == null && split) {
    for (const sep of [' · ', ', ', ' + ', ' – ']) {
      if (!key.includes(sep)) continue;
      const parts = key.split(sep), t = parts.map((p) => tr(p));
      if (t.some((x, i) => x !== parts[i])) { out = t.join(sep); break; }
    }
  }
  if (out == null && split) {
    const m = /^(.*\D) (\d[\d.,:]*\.?)$/.exec(key) || /^(\d[\d.,:]*) (\D.*)$/.exec(key);
    if (m) { const [a, b] = /^\d/.test(m[1]) ? [m[1], tr(m[2])] : [tr(m[1]), m[2]]; if (`${a} ${b}` !== key) out = `${a} ${b}`; }
  }
  return out == null ? s : /^\s*/.exec(s)[0] + out + /\s*$/.exec(s)[0];
}
const ATTRS = ['placeholder', 'title', 'aria-label'];
const ORIG = new WeakMap();   // Textknoten → deutscher Text
const MINE = new WeakMap();   // Textknoten → zuletzt von hier geschriebener Text
function translateRun(first) {
  const run = [];
  for (let x = first; x && x.nodeType === 3; x = x.nextSibling) run.push(x);
  for (const x of run) if (MINE.get(x) !== x.data) ORIG.set(x, x.data);   // neu von der App geschrieben
  const de = run.map((x) => ORIG.get(x)).join('');
  const whole = tr(de, false);   // ganzer Satz nur aus dem Wörterbuch, sonst Stück für Stück
  const parts = whole !== de ? run.map((_, i) => (i === 0 ? whole : '')) : run.map((x) => tr(ORIG.get(x)));
  run.forEach((x, i) => { if (x.data !== parts[i]) x.data = parts[i]; MINE.set(x, parts[i]); });
  return run[run.length - 1];
}
function translateAttrs(el) {
  for (const a of ATTRS) if (el.hasAttribute(a)) { const v = el.getAttribute(a); const t = tr(v); if (t !== v) el.setAttribute(a, t); }
}
/** Kinder eines Elements übersetzen (Textläufe) und in Unterelemente absteigen */
function translateTree(el) {
  if (el.nodeType !== 1 || el.tagName === 'SCRIPT' || el.tagName === 'STYLE') return;
  translateAttrs(el);
  for (let x = el.firstChild; x; x = x.nextSibling) {
    if (x.nodeType === 3) x = translateRun(x);
    else translateTree(x);
  }
}
/** Textlauf um einen Textknoten neu übersetzen */
const retranslate = (n) => { let a = n; while (a.previousSibling?.nodeType === 3) a = a.previousSibling; translateRun(a); };
/** Sprache wechseln. Zurück zu Deutsch lädt die Seite neu (übersetzte Texte stehen schon im Dokument). */
export function setLang(language) {
  const next = language && DICT[language] ? language : 'de';
  if (next === LANG) return;
  if (next === 'de') { LANG = 'de'; observer?.disconnect(); observer = null; location.reload(); return; }
  LANG = next;
  document.documentElement.lang = next;
  translateTree(document.body);
  observer = new MutationObserver((list) => {
    for (const m of list) {
      if (m.type === 'characterData') { if (MINE.get(m.target) !== m.target.data && m.target.parentNode) retranslate(m.target); }
      else if (m.type === 'attributes') translateAttrs(m.target);
      else {
        // geänderte Kinder: Textläufe des Elements neu, neue Elemente ganz
        for (let x = m.target.firstChild; x; x = x.nextSibling) if (x.nodeType === 3) x = translateRun(x);
        m.addedNodes.forEach((x) => { if (x.nodeType === 1) translateTree(x); });
      }
    }
  });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS });
}
