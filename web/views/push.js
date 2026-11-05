// Push-Benachrichtigungen ein-/ausschalten
import { html, useState, useEffect } from '../vendor/preact-htm.js';
import { rpc, useAction, Msg } from '../lib.js';

const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent);
const standalone = window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone;

function b64ToBytes(b64) {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

export function registerServiceWorker() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
}

async function currentSubscription() {
  const reg = await navigator.serviceWorker.getRegistration();
  return reg ? reg.pushManager.getSubscription() : null;
}

export function PushToggle() {
  const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const [state, setState] = useState('…');
  const a = useAction();
  const refresh = async () => {
    if (!supported) return setState('unsupported');
    if (Notification.permission === 'denied') return setState('denied');
    setState((await currentSubscription()) ? 'on' : 'off');
  };
  useEffect(() => { refresh(); }, []);

  const enable = () => a.run(async () => {
    const key = await rpc('vapid_public_key');
    if (!key) throw new Error('Benachrichtigungen sind noch nicht eingerichtet – bitte später erneut versuchen.');
    const reg = await navigator.serviceWorker.register('sw.js');
    await navigator.serviceWorker.ready;
    if ((await Notification.requestPermission()) !== 'granted') { await refresh(); throw new Error('Benachrichtigungen wurden nicht erlaubt.'); }
    const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) });
    const j = sub.toJSON();
    await rpc('save_push_subscription', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
    await refresh();
  }, 'Benachrichtigungen sind an.');
  const disable = () => a.run(async () => {
    const sub = await currentSubscription();
    if (sub) { await rpc('delete_push_subscription', { p_endpoint: sub.endpoint }); await sub.unsubscribe(); }
    await refresh();
  }, 'Benachrichtigungen sind aus.');

  return html`<div class="card stack">
    <div class="row between"><h3>🔔 Benachrichtigungen</h3>
      ${state === 'on' && html`<span class="tag ok">an</span>`}</div>
    <p class="muted small">Waiver-Ergebnisse, Tauschangebote, Draft-Start, abgeschlossene Spieltage und neue Punkte deiner Fahrer.</p>
    ${!supported && isIOS && !standalone ? html`<p class="small">Auf dem iPhone zuerst die App installieren: in Safari auf <strong>Teilen</strong>
        (Quadrat mit Pfeil) → <strong>Zum Home-Bildschirm</strong>, dann die App vom Home-Bildschirm öffnen und hier einschalten.</p>`
      : !supported ? html`<p class="small muted">Dieser Browser unterstützt keine Push-Benachrichtigungen.</p>`
      : state === 'denied' ? html`<p class="small">Benachrichtigungen sind in den Browser- bzw. Handy-Einstellungen blockiert.</p>`
      : html`<div class="row">${state === 'on'
          ? html`<button disabled=${a.busy} onClick=${disable}>Ausschalten</button>`
          : html`<button class="primary" disabled=${a.busy || state === '…'} onClick=${enable}>Einschalten</button>`}</div>`}
    <${Msg} msg=${a.msg} />
  </div>`;
}
