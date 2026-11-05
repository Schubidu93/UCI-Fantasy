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

// Budget spielt nur eine Rolle, wenn Fahrer im Draft etwas kosten (Auktion/Offline) oder Waiver per FAAB laufen
export const draftCosts = (l) => l.draft_mode !== 'snake';
export const budgetRelevant = (l) => draftCosts(l) || l.waiver_mode === 'faab';

export const SOURCE_LABEL = { draft: 'Draft', offline: 'Offline-Draft', waiver: 'Waiver', trade: 'Tausch', admin: 'Admin' };

// ---- Flaggen ---------------------------------------------------------------
// UCI nutzt bei Fahrern IOC-Codes (SLO, GER, NED …), bei Rennen ISO-3-Codes (SVN, DEU …).
const ISO2 = {ABW:'AW',AFG:'AF',AGO:'AO',ALB:'AL',ALG:'DZ',AND:'AD',ANG:'AO',ANT:'AG',ARE:'AE',ARG:'AR',ARM:'AM',ARU:'AW',ASA:'AS',ATG:'AG',AUS:'AU',AUT:'AT',AZE:'AZ',BAH:'BS',BAN:'BD',BAR:'BB',BDI:'BI',BEL:'BE',BEN:'BJ',BER:'BM',BFA:'BF',BGD:'BD',BGR:'BG',BHR:'BH',BHS:'BS',BHU:'BT',BIH:'BA',BIZ:'BZ',BLR:'BY',BOL:'BO',BOT:'BW',BRA:'BR',BRB:'BB',BRN:'BH',BRU:'BN',BUL:'BG',BUR:'BF',CAF:'CF',CAM:'KH',CAN:'CA',CAY:'KY',CGO:'CG',CHA:'TD',CHE:'CH',CHI:'CL',CHL:'CL',CHN:'CN',CIV:'CI',CMR:'CM',COD:'CD',COK:'CK',COL:'CO',COM:'KM',CPV:'CV',CRC:'CR',CRI:'CR',CRO:'HR',CUB:'CU',CUW:'CW',CYP:'CY',CZE:'CZ',DEN:'DK',DEU:'DE',DJI:'DJ',DMA:'DM',DNK:'DK',DOM:'DO',DZA:'DZ',ECU:'EC',EGY:'EG',ERI:'ER',ESA:'SV',ESP:'ES',EST:'EE',ETH:'ET',FIJ:'FJ',FIN:'FI',FJI:'FJ',FRA:'FR',FRO:'FO',FSM:'FM',GAB:'GA',GAM:'GM',GBR:'GB',GBS:'GW',GEO:'GE',GEQ:'GQ',GER:'DE',GHA:'GH',GIB:'GI',GLP:'GP',GMB:'GM',GNB:'GW',GRC:'GR',GRE:'GR',GRL:'GL',GRN:'GD',GTM:'GT',GUA:'GT',GUI:'GN',GUM:'GU',GUY:'GY',HAI:'HT',HKG:'HK',HND:'HN',HON:'HN',HRV:'HR',HUN:'HU',IDN:'ID',INA:'ID',IND:'IN',IRI:'IR',IRL:'IE',IRN:'IR',IRQ:'IQ',ISL:'IS',ISR:'IL',ISV:'VI',ITA:'IT',IVB:'VG',JAM:'JM',JOR:'JO',JPN:'JP',KAZ:'KZ',KEN:'KE',KGZ:'KG',KHM:'KH',KIR:'KI',KNA:'KN',KOR:'KR',KOS:'XK',KSA:'SA',KUW:'KW',KWT:'KW',LAO:'LA',LAT:'LV',LBA:'LY',LBN:'LB',LBR:'LR',LBY:'LY',LCA:'LC',LES:'LS',LIE:'LI',LKA:'LK',LSO:'LS',LTU:'LT',LUX:'LU',LVA:'LV',MAC:'MO',MAD:'MG',MAR:'MA',MAS:'MY',MAW:'MW',MCO:'MC',MDA:'MD',MDG:'MG',MDV:'MV',MEX:'MX',MGL:'MN',MHL:'MH',MKD:'MK',MLI:'ML',MLT:'MT',MMR:'MM',MNE:'ME',MNG:'MN',MON:'MC',MOZ:'MZ',MRI:'MU',MRT:'MR',MTN:'MR',MTQ:'MQ',MUS:'MU',MWI:'MW',MYA:'MM',MYS:'MY',NAM:'NA',NCA:'NI',NCL:'NC',NED:'NL',NEP:'NP',NER:'NE',NGA:'NG',NGR:'NG',NIC:'NI',NIG:'NE',NLD:'NL',NOR:'NO',NRU:'NR',NZL:'NZ',OMA:'OM',OMN:'OM',PAK:'PK',PAN:'PA',PAR:'PY',PER:'PE',PHI:'PH',PHL:'PH',PLE:'PS',PLW:'PW',PNG:'PG',POL:'PL',POR:'PT',PRI:'PR',PRK:'KP',PRT:'PT',PRY:'PY',PSE:'PS',PUR:'PR',PYF:'PF',QAT:'QA',REU:'RE',ROU:'RO',RSA:'ZA',RUS:'RU',RWA:'RW',SAM:'WS',SAU:'SA',SDN:'SD',SEN:'SN',SEY:'SC',SGP:'SG',SKN:'KN',SLB:'SB',SLE:'SL',SLO:'SI',SLV:'SV',SMR:'SM',SOL:'SB',SOM:'SO',SRB:'RS',SRI:'LK',SSD:'SS',STP:'ST',SUD:'SD',SUI:'CH',SUR:'SR',SVK:'SK',SVN:'SI',SWE:'SE',SWZ:'SZ',SXM:'SX',SYC:'SC',SYR:'SY',TAN:'TZ',TGA:'TO',THA:'TH',TJK:'TJ',TKM:'TM',TLS:'TL',TOG:'TG',TON:'TO',TPE:'TW',TTO:'TT',TUN:'TN',TUR:'TR',TUV:'TV',TWN:'TW',TZA:'TZ',UAE:'AE',UGA:'UG',UKR:'UA',URU:'UY',URY:'UY',USA:'US',UZB:'UZ',VAN:'VU',VCT:'VC',VEN:'VE',VGB:'VG',VIE:'VN',VIN:'VC',VIR:'VI',VNM:'VN',WSM:'WS',YEM:'YE',ZAF:'ZA',ZAM:'ZM',ZIM:'ZW',ZMB:'ZM',ZWE:'ZW'};
export function flag(code) {
  const iso = ISO2[(code || '').trim().toUpperCase()];
  if (!iso) return '';
  return String.fromCodePoint(...[...iso].map((ch) => 0x1f1e6 + ch.charCodeAt(0) - 65));
}
export const withFlag = (code) => (code ? `${flag(code)} ${code.trim()}`.trim() : '');

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
    <span class="rider-meta">${[r.nation && withFlag(r.nation), r.birth_date && `Jg. ${r.birth_date.slice(0, 4)}`, r.team, r.uci_rank && `UCI #${r.uci_rank}`].filter(Boolean).join(' · ')}</span>
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
