// Spielregeln – allgemeine Regeln plus die Einstellungen der aktuellen Liga
import { html } from '../vendor/preact-htm.js';
import { draftCosts, fmtDate } from '../lib.js';

const DRAFT = {
  live: 'Live-Auktion',
  blind: 'Blind-Auktion (verdeckte Gebote)',
  snake: 'Snake-Draft',
  offline: 'Offline-Draft (Kader trägt der Admin ein)',
};

export function Rules({ c }) {
  const l = c.league;
  const two = l.transfer_mode === 'waiver_free';
  const lineup = l.scoring_mode === 'lineup';
  const auction = ['live', 'blind'].includes(l.draft_mode);
  const row = (k, v) => html`<tr><td>${k}</td><td>${v}</td></tr>`;
  return html`<div class="stack rules">
    <section class="card">
      <h2>So funktioniert UCI Fantasy</h2>
      <ol class="rule-steps">
        <li><strong>Team draften:</strong> ${l.roster_size} Radprofis pro Manager.</li>
        ${lineup ? html`<li><strong>Aufstellen:</strong> vor jedem Spieltag ${l.lineup_size} der ${l.roster_size} Fahrer.</li>` : html`<li><strong>Alle zählen:</strong> jeder Fahrer im Kader punktet.</li>`}
        <li><strong>Punkte sammeln:</strong> die UCI-Punkte aus den Rennergebnissen.</li>
        <li><strong>Kader verbessern:</strong> per Waiver und Tausch. Am Saisonende gewinnt, wer die meisten Punkte hat.</li>
      </ol>
    </section>

    <section class="card">
      <h3>Diese Liga</h3>
      <table class="tbl rule-tbl"><tbody>
        ${row('Wertung', l.gender === 'women' ? 'Frauen Elite' : 'Männer Elite')}
        ${row('Saison', `${fmtDate(l.season_start)} – ${fmtDate(l.season_end)}`)}
        ${row('Mitspieler', `${c.managers.length} von max. ${l.max_managers}`)}
        ${row('Kader', `${l.roster_size} Fahrer${l.max_per_team ? `, höchstens ${l.max_per_team} pro Profiteam` : ''}`)}
        ${row('Modus', lineup ? `Aufstellung, ${l.lineup_size} von ${l.roster_size} werten` : 'Gesamtkader zählt')}
        ${row('Draft', DRAFT[l.draft_mode] + (auction ? ` · ${l.draft_order === 'ranking' ? 'nach UCI-Rang' : 'reihum nominieren'}` : ''))}
        ${l.draft_mode !== 'offline' && row(l.draft_mode === 'snake' ? 'Zeit pro Pick' : l.draft_mode === 'blind' ? 'Zeit pro Fahrer' : 'Zeit pro Gebot', `${l.bid_seconds} Sekunden`)}
        ${draftCosts(l) ? row('Budget', `${l.budget} Punkte pro Manager`) : l.waiver_mode === 'faab' && row('FAAB-Budget', `${l.budget} Punkte für Waiver-Gebote`)}
        ${row('Transfers', two ? 'Waiver-Runde, dann freie Phase' : 'nur Waiver')}
        ${row('Waiver', l.waiver_mode === 'faab' ? 'FAAB (verdeckt bieten)' : 'Priorität (Letzter zuerst)')}
        ${l.keeper_count > 0 && row('Keeper', `bis ${l.keeper_count}, Preis Vorjahr + ${l.keeper_surcharge}`)}
      </tbody></table>
    </section>

    <details class="card rule-sec" open=${['setup', 'drafting'].includes(l.status)}>
      <summary><h3>Draft: ${DRAFT[l.draft_mode]}</h3></summary>
      <ul>
        ${l.draft_mode === 'snake' ? html`
          <li>Reihum je ein Fahrer, jede Runde in umgekehrter Reihenfolge (1–2–3, 3–2–1). Startreihenfolge wird ausgelost.</li>
          <li>${l.bid_seconds} Sekunden pro Pick – sonst wird automatisch der beste freie Fahrer nach UCI-Rang gewählt.</li>
          <li>Fahrer kosten nichts${l.waiver_mode === 'faab' ? `; die ${l.budget} Punkte bleiben für FAAB-Waiver` : ''}.</li>`
        : l.draft_mode === 'live' ? html`
          <li><strong>${l.budget} Budgetpunkte</strong> pro Manager. Fahrer kommen ${l.draft_order === 'ranking' ? 'nach UCI-Rang' : 'reihum nominiert'} unter den Hammer.</li>
          <li>Jedes Gebot +1 oder mehr, die Uhr springt auf ${l.bid_seconds} Sekunden zurück. Läuft sie ab, gewinnt das Höchstgebot.</li>
          <li>Bietet niemand, ist der Fahrer danach frei. Am Ende füllen alle reihum für je 1 Punkt auf.</li>`
        : l.draft_mode === 'blind' ? html`
          <li><strong>${l.budget} Budgetpunkte</strong> pro Manager. Fahrer kommen ${l.draft_order === 'ranking' ? 'nach UCI-Rang' : 'reihum nominiert'} an die Reihe.</li>
          <li>Pro Fahrer ${l.bid_seconds} Sekunden für ein <strong>verdecktes Gebot</strong>; das höchste gewinnt zu genau diesem Preis.</li>
          <li>Gleichstand: Stechen in Schritten von 1, bis keiner mehr erhöht.</li>
          <li>Bietet niemand, ist der Fahrer danach frei.</li>`
        : html`<li>Offline – der Admin trägt die Kader samt Preisen ein.</li>`}
        ${auction && html`<li>Höchstgebot = Restbudget − (offene Plätze − 1), damit jeder Kader voll wird.</li>`}
        <li>Mit Draft-Termin startet der Draft automatisch${l.draft_mode !== 'offline' ? '; wer dran ist, bekommt eine Push-Nachricht' : ''}.</li>
      </ul>
    </details>

    <details class="card rule-sec">
      <summary><h3>Punkte</h3></summary>
      <ul>
        <li>Es zählen genau die <strong>UCI-Punkte</strong> eines Ergebnisses – vom kleinen .2-Rennen bis zum Tour-Sieg (1.300).</li>
        <li>Etappe, Gesamtwertung, Trikots und Führungstage zählen jeweils einzeln.</li>
        ${lineup
          ? html`<li>Nur die <strong>${l.lineup_size} aufgestellten</strong> Fahrer punkten. Änderbar bis zum Stichtag; ohne Änderung gilt die vorige Aufstellung (beim ersten Spieltag: deine teuersten Fahrer).</li>`
          : html`<li>Alle Fahrer deines Kaders punkten.</li>`}
        <li>Punkte zählen nur, solange der Fahrer in deinem Kader${lineup ? ' und aufgestellt' : ''} ist. Korrekturen der UCI (z. B. Aberkennung) werden übernommen, bis der Spieltag eingefroren ist.</li>
      </ul>
    </details>

    <details class="card rule-sec">
      <summary><h3>Spieltage, Waiver und Tausch</h3></summary>
      <p class="muted small">Spieltage legt der Admin als Zeiträume fest (z. B. Klassiker, Giro, Tour, Vuelta); alle stehen unter Liga → Spieltage.</p>
      <h4 class="rule-sub">Ablauf vor jedem Spieltag</h4>
      <table class="tbl rule-tbl"><tbody>
        ${two ? html`
          ${row('Waiver-Runde', 'bis eine Woche vor Spieltagstart (bei kurzen Spieltagen bis zur Hälfte des vorigen), dann Auswertung.')}
          ${row('Freie Phase', 'danach bis zum Stichtag: freie Fahrer sofort holen und abgeben – wer zuerst kommt.')}
          ${row('Stichtag', `Ende des Vortags: Tausche ausgeführt, Kader${lineup ? ' und Aufstellung' : ''} fest.`)}`
        : html`
          ${row('Waiver', 'Anträge vom vorigen bis zum eigenen Stichtag.')}
          ${row('Stichtag', `Vortag 20 Uhr: Waiver und Tausche ausgeführt, Kader${lineup ? ' und Aufstellung' : ''} fest.`)}`}
        ${row('Spieltag', 'Wechsel gelten erst ab dem nächsten Spieltag. Punkte zwischen zwei Spieltagen verfallen.')}
        ${row('Danach', '7 Tage nach Ende eingefroren; bis dahin werden Korrekturen übernommen.')}
      </tbody></table>
      <h4 class="rule-sub">Waiver</h4>
      <ul>
        <li>Freien Fahrer wählen und einen eigenen abgeben (Kader bleibt voll); mehrere Anträge in Wunschreihenfolge.</li>
        <li>${l.waiver_mode === 'faab'
          ? 'FAAB: verdeckt mit dem Restbudget bieten; Höchstgebot gewinnt, bei Gleichstand der schlechter Platzierte.'
          : 'Priorität: Tabellenletzter zuerst, höchstens ein Fahrer pro Runde; vor dem ersten Spieltag umgekehrte Draft-Reihenfolge.'}</li>
        <li>${two ? 'In der Waiver-Runde Abgegebene sind ab der freien Phase wieder frei, in der freien Phase Abgegebene sofort.' : 'Abgegebene sind bis zum nächsten Stichtag gesperrt.'}</li>
        <li>Fahrer mit Karriereende oder Sperre (vom Admin markiert) sind sofort ersetzbar.</li>
      </ul>
      <h4 class="rule-sub">Tausch</h4>
      <ul>
        <li>Beide stimmen zu, dann 24 Stunden Veto für den Admin; ausgeführt zum nächsten Stichtag.</li>
        <li>Ungleich möglich (1 gegen 2): Wer mehr bekommt, gibt dafür eigene Fahrer ab; wer weniger bekommt, füllt per Waiver auf.</li>
      </ul>
      <h4 class="rule-sub">Tabelle und Nachrichten</h4>
      <ul>
        <li>Gleichstand: mehr Spieltagssiege, dann bester Einzelspieltag${draftCosts(l) ? ', dann weniger Budget ausgegeben' : ''}.</li>
        <li>Push: „Neue Punkte“, Wochen-Zusammenfassung (montags 9 Uhr), Waiver-Ergebnisse und alles rund um Tausche.</li>
      </ul>
    </details>

    <details class="card rule-sec">
      <summary><h3>Daten</h3></summary>
      <p class="muted small">Alles von der UCI: Ergebnisse aus UCI DataRide, künftige Rennen zusätzlich aus dem UCI-Wettkampfverzeichnis. Ergebnisse ab 2025.</p>
      <table class="tbl rule-tbl"><tbody>
        ${row('Ergebnisse', 'täglich 20 Uhr: neue Rennen, Rundfahrten Etappe für Etappe, Rennen der letzten 3 Tage. Große Rennen meist am selben Abend, kleine 1–2 Tage später.')}
        ${row('Kontrolle', 'mittwochs alle Rennen der letzten 3 Wochen neu – Korrekturen der UCI kommen so an.')}
        ${row('Ergebnislisten', 'WorldTour, ProSeries und WM vollständig; sonst Top 25 und alle Plätze mit Punkten.')}
        ${row('Fahrer', 'täglich 6 Uhr: alle mit UCI-Punkten (Rang, Team, Nation); neue sind automatisch frei.')}
        ${row('Abgleich', 'mit der UCI-Weltrangliste; Punkte aus Mannschaftswertungen (z. B. Mixed-Staffel der WM) werden nachgetragen.')}
        ${row('Kalender', 'mit dem Ergebnisabruf, inkl. nächster Saison; noch nicht in DataRide stehende Rennen als „vorläufig“.')}
        ${row('„Punkte 2026“', 'alle Rennen vom 1.1. bis 31.12.2026; die Weltrangliste (52 Wochen) steht getrennt.')}
      </tbody></table>
      <p class="muted small">Bei falschen Daten kann der Admin Punkte korrigieren – jede Korrektur wird protokolliert.</p>
    </details>
  </div>`;
}
