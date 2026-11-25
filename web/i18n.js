// Übersetzung der Oberfläche (beide Apps gleich; Tests: tests/i18n.test.ts in Athletics Fantasy). Die App ist auf Deutsch
// geschrieben. Für eine andere Sprache (z. B. Niederländisch in niederländischen Ligen) meldet die Sportart-Schicht ein Wörterbuch
// an (registerTexts); setLang schaltet um. Übersetzt wird die fertige Seite: je Element der zusammenhängende Text (alle Textstücke
// zwischen zwei Tags, also ganze Sätze samt eingesetzter Werte), dazu placeholder/title/aria-label/label. Schlüssel im Wörterbuch:
// der deutsche Text mit {} für eingesetzte Werte; in der Übersetzung stehen sie als {0}, {1} … (selbst wieder übersetzt).
// Ohne Wörterbuch bleibt alles deutsch (UCI Fantasy).
const DICT = {};   // Sprache → { entries: [[Schlüssel, Übersetzung]], exact: Map, templates: [{ re, chunk, out, size }], patterns: [[RegExp, Ersatz]], cache: Map }
let LANG = 'de';
let observer = null;
const squash = (s) => s.replace(/\s+/g, ' ').trim();
const escRe = (s) => s.replace(/[.*+?^$()|[\]\\{}]/g, '\\$&');
// Leerraum am Rand eines festen Stücks darf neben eingesetzten Werten fehlen (htm entfernt dort Zeilenumbrüche) – aber nur an einer
// Wortgrenze, damit „{} ab {}“ nicht in „Stabhochsprung“ passt
const EDGE = '(?:\\s+|\\b)';
const partRe = (x) => (x && !x.trim() ? '\\s+' : escRe(x).replace(/^ +/, EDGE).replace(/ +$/, EDGE));

export const lang = () => LANG;
/** Alle Einträge eines Wörterbuchs [Schlüssel, Übersetzung] (für Tests) */
export const dictionary = (language) => DICT[language]?.entries ?? [];
export function registerTexts(language, texts = {}, patterns = []) {
  const d = DICT[language] ||= { entries: [], exact: new Map(), templates: [], patterns: [] };
  for (const [k, out] of Object.entries(texts)) {
    const key = squash(k);
    d.entries.push([key, out]);
    if (!key.includes('{}')) { d.exact.set(key, out); continue; }
    const parts = key.split('{}');
    d.templates.push({ re: new RegExp(`^${parts.map(partRe).join('([\\s\\S]*?)')}$`), out,
      chunk: parts.reduce((a, b) => (b.length > a.length ? b : a), '').trim(), size: parts.join('').length });
  }
  d.templates.sort((a, b) => b.size - a.size);   // genauere Vorlagen zuerst
  d.patterns.push(...patterns);
  d.cache = new Map();
}

/** Übersetzung aus dem Wörterbuch (genau, Vorlage oder Muster), sonst null */
function lookup(d, key, language) {
  let out = d.exact.get(key);
  if (out == null) {
    for (const t of d.templates) {
      if (!key.includes(t.chunk)) continue;
      const m = t.re.exec(key);
      // kurze, allgemeine Vorlagen („{} ab {}“) nicht auf lange Sätze anwenden
      if (!m || (t.size < 12 && m.slice(1).join('').length > 40)) continue;
      const vals = m.slice(1).map((v) => translate(v, language));
      out = typeof t.out === 'function' ? t.out(...vals) : t.out.replace(/\{(\d)\}/g, (_, i) => vals[i]);
      break;
    }
  }
  if (out == null) for (const [re, rep] of d.patterns) if (re.test(key)) { out = key.replace(re, rep); break; }
  return out ?? null;
}

/** Einen Text in eine Sprache übersetzen (Leerraum am Rand bleibt); unbekannte Texte bleiben deutsch.
 *  split = false: nur ganze Treffer aus dem Wörterbuch, sonst auch Teile (Sätze, „ · “, „, “, Zahl am Ende) einzeln */
export function translate(s, language, split = true) {
  const d = DICT[language];
  if (!d || !s) return s;
  // dieselben Texte kommen in Listen hundertfach vor: Ergebnis merken
  const ck = (split ? '1' : '0') + s;
  let hit = d.cache.get(ck);
  if (hit === undefined) {
    if (d.cache.size > 20000) d.cache.clear();
    d.cache.set(ck, hit = translateUncached(s, language, split, d));
  }
  return hit;
}
function translateUncached(s, language, split, d) {
  const key = squash(s);
  if (!key) return s;
  let out = lookup(d, key, language);
  if (out == null && split) {
    // aneinandergehängte Sätze (z. B. Draft-Report): jeweils die längste Satzfolge, die im Wörterbuch steht
    const sentences = key.split(/(?<=[.!?…]) (?=[A-ZÄÖÜ„(])/);
    if (sentences.length > 1) {
      const t = [];
      for (let i = 0; i < sentences.length; ) {
        let j = sentences.length, hit = null;
        for (; j > i + 1 && hit == null; j--) hit = lookup(d, sentences.slice(i, j).join(' '), language);
        if (hit != null) { t.push(hit); i = j + 1; } else { t.push(translate(sentences[i], language)); i++; }
      }
      if (t.join(' ') !== key) out = t.join(' ');
    }
  }
  if (out == null && split) {
    for (const sep of [' · ', ', ', ' + ', ' – ']) {
      if (!key.includes(sep)) continue;
      const parts = key.split(sep), t = parts.map((p) => translate(p, language));
      if (t.some((x, i) => x !== parts[i])) { out = t.join(sep); break; }
    }
  }
  if (out == null && split) {
    // Trennzeichen am Rand („ · Vorlauf 2“ hinter einem eingesetzten Wert): Rest übersetzen
    const m = /^([·,–+:]\s*)(.+)$/.exec(key) || /^(.+?)(\s*[·,–+:])$/.exec(key);
    if (m) {
      const [a, b] = /^[·,–+:]/.test(m[1]) ? [m[1], translate(m[2], language)] : [translate(m[1], language), m[2]];
      if (a + b !== key) out = a + b;
    }
  }
  if (out == null && split) {
    const m = /^(.*\D) (\d[\d.,:]*\.?)$/.exec(key) || /^(\d[\d.,:]*) (\D.*)$/.exec(key);
    if (m) {
      const [a, b] = /^\d/.test(m[1]) ? [m[1], translate(m[2], language)] : [translate(m[1], language), m[2]];
      if (`${a} ${b}` !== key) out = `${a} ${b}`;
    }
  }
  return out == null ? s : /^\s*/.exec(s)[0] + out + /\s*$/.exec(s)[0];
}
/** In die aktuelle Sprache übersetzen */
export const tr = (s, split = true) => translate(s, LANG, split);

const ATTRS = ['placeholder', 'title', 'aria-label', 'label'];
const ORIG = new WeakMap();   // Textknoten → deutscher Text
const MINE = new WeakMap();   // Textknoten → zuletzt von hier geschriebener Text
const ATTR_ORIG = new WeakMap();   // Element → { Attribut: deutscher Wert }
const TOUCHED = new Set();   // geänderte Textknoten und Elemente (zum Zurücksetzen auf Deutsch)
const touch = (n) => {
  if (TOUCHED.size > 20000) for (const x of TOUCHED) if (!x.isConnected) TOUCHED.delete(x);   // entfernte Knoten vergessen
  TOUCHED.add(n);
};
function translateRun(first) {
  const run = [];
  for (let x = first; x && x.nodeType === 3; x = x.nextSibling) run.push(x);
  for (const x of run) if (MINE.get(x) !== x.data) ORIG.set(x, x.data);   // neu von der App geschrieben
  const de = run.map((x) => ORIG.get(x)).join('');
  const whole = tr(de, false);   // ganzer Satz nur aus dem Wörterbuch, sonst Stück für Stück
  const parts = whole !== de ? run.map((_, i) => (i === 0 ? whole : '')) : run.map((x) => tr(ORIG.get(x)));
  run.forEach((x, i) => { if (x.data !== parts[i]) { x.data = parts[i]; touch(x); } MINE.set(x, parts[i]); });
  return run[run.length - 1];
}
function translateAttrs(el) {
  for (const a of ATTRS) {
    if (!el.hasAttribute(a)) continue;
    const v = el.getAttribute(a), t = tr(v);
    if (t === v) continue;
    const o = ATTR_ORIG.get(el) || {};
    if (!(a in o)) { o[a] = v; ATTR_ORIG.set(el, o); }
    el.setAttribute(a, t);
    touch(el);
  }
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
/** Alle übersetzten Texte und Attribute wieder auf Deutsch setzen */
function restoreGerman() {
  for (const n of TOUCHED) {
    if (!n.isConnected) continue;
    if (n.nodeType === 3) { if (ORIG.has(n)) n.data = ORIG.get(n); }
    else for (const [a, v] of Object.entries(ATTR_ORIG.get(n) || {})) n.setAttribute(a, v);
  }
  TOUCHED.clear();
}
/** Sprache wechseln (z. B. beim Öffnen einer Liga). Zurück zu Deutsch: übersetzte Texte zurücksetzen, ohne neu zu laden. */
export function setLang(language) {
  const next = language && DICT[language] ? language : 'de';
  if (next === LANG) return;
  observer?.disconnect();
  observer = null;
  if (LANG !== 'de') restoreGerman();
  LANG = next;
  document.documentElement.lang = next;
  if (next === 'de') return;
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
