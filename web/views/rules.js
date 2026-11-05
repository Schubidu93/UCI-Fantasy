// Spielregeln – allgemeine Regeln plus die Einstellungen der aktuellen Liga
import { html } from '../vendor/preact-htm.js';
import { fmtDate, draftCosts } from '../lib.js';

const DRAFT = {
  live: 'Live-Auktion',
  snake: 'Snake-Draft',
  offline: 'Offline-Draft (Kader trägt der Admin ein)',
};

export function Rules({ c }) {
  const l = c.league;
  const row = (k, v) => html`<tr><td>${k}</td><td><strong>${v}</strong></td></tr>`;
  return html`<div class="stack rules">
    <section class="card">
      <h2>So funktioniert UCI Fantasy</h2>
      <p>Jeder Manager stellt ein Team aus echten Radprofis zusammen und sammelt die <strong>UCI-Weltranglistenpunkte</strong>,
        die seine Fahrer im Spielzeitraum dazugewinnen. Wer am Saisonende die meisten Punkte hat, gewinnt die Liga.</p>
    </section>

    <section class="card">
      <h3>Einstellungen dieser Liga</h3>
      <table class="tbl"><tbody>
        ${row('Wertung', l.gender === 'women' ? 'Frauen Elite' : 'Männer Elite')}
        ${row('Saison', `${fmtDate(l.season_start)} – ${fmtDate(l.season_end)}`)}
        ${row('Mitspieler', `${c.managers.length} von max. ${l.max_managers}`)}
        ${row('Fahrer pro Team', l.roster_size)}
        ${row('Max. Fahrer pro Profiteam', l.max_per_team || 'keine Grenze')}
        ${row('Wertungsmodus', l.scoring_mode === 'lineup' ? `Aufstellung: ${l.lineup_size} von ${l.roster_size} Fahrern werten` : 'Gesamtkader zählt')}
        ${row('Draft', DRAFT[l.draft_mode] + (l.draft_mode === 'live' ? ` · ${l.draft_order === 'ranking' ? 'Reihenfolge nach UCI-Rang' : 'reihum nominieren'}` : ''))}
        ${l.draft_mode !== 'offline' && row(l.draft_mode === 'snake' ? 'Zeit pro Pick' : 'Zeit pro Gebot', `${l.bid_seconds} Sekunden`)}
        ${draftCosts(l) ? row('Budget', `${l.budget} Punkte pro Manager`) : l.waiver_mode === 'faab' && row('FAAB-Budget', `${l.budget} Punkte pro Manager für Waiver-Gebote`)}
        ${row('Waiver', l.waiver_mode === 'faab' ? 'FAAB – verdeckt mit dem Restbudget bieten' : 'Priorität – Tabellenletzter zuerst')}
        ${l.keeper_count > 0 && row('Keeper', `bis zu ${l.keeper_count} Fahrer aus der Vorsaison, Preis Vorjahr + ${l.keeper_surcharge}`)}
      </tbody></table>
    </section>

    <section class="card">
      <h3>Draft</h3>
      ${l.draft_mode === 'live' ? html`<ul>
          <li>Jeder Manager hat <strong>${l.budget} Budgetpunkte</strong>. Die Fahrer kommen ${l.draft_order === 'ranking' ? 'in der Reihenfolge der UCI-Rangliste' : 'reihum nominiert (Startgebot 1)'} unter den Hammer.</li>
          <li>Jedes Gebot muss das vorige um mindestens 1 übertreffen und setzt die Uhr auf ${l.bid_seconds} Sekunden zurück. Läuft sie ab, gewinnt das Höchstgebot.</li>
          <li>Höchstgebot = Restbudget − (offene Kaderplätze − 1), damit jeder Kader füllbar bleibt.</li>
          <li>Bietet niemand, wird der Fahrer übersprungen und ist danach frei. Ist die Rangliste durch, füllen alle ihre Restplätze reihum für je 1 Punkt.</li>
        </ul>`
      : l.draft_mode === 'snake' ? html`<ul>
          <li>Die Manager wählen reihum je einen Fahrer; in jeder Runde dreht sich die Reihenfolge um (1–2–3 … 3–2–1). Die Reihenfolge wird beim Start ausgelost.</li>
          <li>Pro Pick gibt es ${l.bid_seconds} Sekunden. Läuft die Uhr ab, wird automatisch der beste freie Fahrer nach UCI-Rang gewählt.</li>
          <li>Fahrer kosten im Snake-Draft nichts${l.waiver_mode === 'faab' ? `; die ${l.budget} Budgetpunkte bleiben für FAAB-Waiver` : ''}.</li>
        </ul>`
      : html`<p>Der Draft findet offline statt. Der Admin trägt danach die Kader samt Preisen ein (oder lädt eine CSV hoch).</p>`}
      <p class="muted small">Der Admin kann einen Draft-Termin festlegen – dann läuft für alle ein Countdown und der Draft startet automatisch.</p>
    </section>

    <section class="card">
      <h3>Punkte</h3>
      <ul>
        <li>Ein Fahrer bringt seinem Manager genau die <strong>UCI-Punkte</strong>, die er für ein Ergebnis in der Weltrangliste erhält – vom kleinen .2-Rennen bis zum Tour-Sieg (1.300).</li>
        <li>Etappen, Gesamtwertung, Trikots und Führungstage zählen jeweils einzeln, so wie die UCI sie vergibt.</li>
        <li>Gezählt wird ab dem Tag, an dem der Fahrer ins Team kommt, bis zum Tag seiner Abgabe.</li>
        <li>Einmal gutgeschriebene Punkte bleiben – anders als im rollierenden 52-Wochen-Ranking der UCI.</li>
        <li>Die UCI rechnet ihr Ranking <strong>einmal pro Woche</strong> neu; neue Punkte erscheinen deshalb mit einigen Tagen Verzögerung.</li>
        <li>Aberkannte Ergebnisse (z. B. Doping) werden automatisch abgezogen, solange der Spieltag nicht eingefroren ist.</li>
      </ul>
    </section>

    <section class="card">
      <h3>Spieltage und Tabelle</h3>
      <ul>
        <li>Der Admin legt Spieltage als Zeiträume fest (z. B. Klassiker, Giro, Tour, Vuelta). Punkte zwischen zwei Spieltagen verfallen.</li>
        <li>Jeder Spieltag hat einen <strong>Stichtag</strong> (Standard: Start um 00:00 Uhr). Waiver, Tausch und Aufstellung wirken ab diesem Spieltag.</li>
        <li>Ein Spieltag schließt nach seinem Ende und wird 7 Tage später eingefroren; bis dahin werden Korrekturen automatisch übernommen.</li>
        <li>Gleichstand in der Tabelle: zuerst mehr Spieltagssiege, dann höchster Einzelspieltag${draftCosts(l) ? ', dann weniger ausgegebenes Budget' : ''}.</li>
      </ul>
    </section>

    <section class="card">
      <h3>Waiver und Tausch</h3>
      <ul>
        <li>Freie Fahrer holst du per <strong>Waiver-Antrag</strong>: freien Fahrer wählen, eigenen Fahrer abgeben (der Kader bleibt voll). Mehrere Anträge in Wunschreihenfolge sind möglich.</li>
        <li>${l.waiver_mode === 'faab'
          ? html`<strong>FAAB:</strong> Du bietest verdeckt mit deinem Restbudget; das Höchstgebot gewinnt, bei Gleichstand der schlechter Platzierte.`
          : html`<strong>Priorität:</strong> Der Tabellenletzte wählt zuerst, dann der Vorletzte … Pro Runde bekommt jeder höchstens einen Fahrer. Vor dem ersten Spieltag gilt die umgekehrte Draft-Reihenfolge.`}</li>
        <li>Abgegebene Fahrer sind bis zum nächsten Stichtag gesperrt.</li>
        <li>Fahrer mit Karriereende oder Sperre (vom Admin markiert) können sofort außer der Reihe ersetzt werden.</li>
        <li><strong>Tausch</strong> zwischen Managern: Beide müssen zustimmen, danach hat der Admin 24 Stunden Vetorecht. Ausgeführt wird zum nächsten Stichtag.</li>
      </ul>
    </section>

    <section class="card">
      <h3>Daten</h3>
      <p class="small">Fahrer, Ranglisten und Ergebnisse stammen aus <strong>UCI DataRide</strong>, der offiziellen Seite der UCI-Weltrangliste.
        Fahrerpunkte werden täglich abgerufen, Rennergebnisse und das Ranking wöchentlich (mittwochs). Bei falschen Daten kann der Admin Punkte manuell korrigieren – jede Korrektur wird protokolliert.</p>
    </section>
  </div>`;
}
