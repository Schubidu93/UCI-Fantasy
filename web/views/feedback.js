// Feedback: Text und Bilder (z. B. Bildschirmfotos) – kommen per E-Mail beim Betreiber an
import { html, useState } from '../vendor/preact-htm.js';
import { rpc, useAction, Msg } from '../lib.js';

const MAX_IMAGES = 5;

// Bild verkleinern (längste Seite 1600 px) und als JPEG (Base64) liefern – spart Datenvolumen
function shrink(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const k = Math.min(1, 1600 / Math.max(img.width, img.height));
      const cv = document.createElement('canvas');
      cv.width = Math.round(img.width * k); cv.height = Math.round(img.height * k);
      cv.getContext('2d').drawImage(img, 0, 0, cv.width, cv.height);
      URL.revokeObjectURL(url);
      const dataUrl = cv.toDataURL('image/jpeg', 0.82);
      resolve({ mime: 'image/jpeg', data: dataUrl.split(',')[1], preview: dataUrl });
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Bild konnte nicht gelesen werden.')); };
    img.src = url;
  });
}

export function Feedback({ c }) {
  const [text, setText] = useState('');
  const [images, setImages] = useState([]);
  const [sent, setSent] = useState(false);
  const a = useAction();

  const add = (e) => a.run(async () => {
    const files = [...e.target.files].slice(0, MAX_IMAGES - images.length);
    e.target.value = '';
    const out = [];
    for (const f of files) out.push(await shrink(f));
    setImages([...images, ...out]);
  });
  const send = () => a.run(async () => {
    await rpc('submit_feedback', {
      p_message: text, p_league: c?.league?.id || null, p_page: location.hash,
      p_device: `${navigator.userAgent} · ${screen.width}×${screen.height}`,
      p_images: images.map(({ mime, data }) => ({ mime, data })),
    });
    setText(''); setImages([]); setSent(true);
  });

  if (sent) return html`<section class="card stack">
    <h2>Danke! 🙌</h2>
    <p>Dein Feedback ist angekommen und wird per E-Mail weitergeleitet.</p>
    <div class="row"><button onClick=${() => setSent(false)}>Noch etwas schicken</button></div>
  </section>`;

  return html`<section class="card stack">
    <h2>Feedback</h2>
    <p class="muted small">Fehler gefunden, Idee oder Wunsch? Schreib es hier rein – gern mit Bildschirmfoto.
      Deine E-Mail-Adresse wird mitgeschickt, damit eine Antwort möglich ist.</p>
    <textarea rows="6" maxlength="5000" placeholder="Was ist dir aufgefallen?" value=${text}
      onInput=${(e) => setText(e.target.value)}></textarea>
    ${images.length > 0 && html`<div class="fb-thumbs">${images.map((img, i) => html`<div class="fb-thumb" key=${i}>
      <img src=${img.preview} alt="" />
      <button class="small ghost" aria-label="Bild entfernen" onClick=${() => setImages(images.filter((_, j) => j !== i))}>✕</button></div>`)}</div>`}
    ${images.length < MAX_IMAGES && html`<label class="button fb-add">📷 Bild hinzufügen
      <input type="file" accept="image/*" multiple onChange=${add} hidden /></label>`}
    <div class="row"><button class="primary" disabled=${a.busy || (!text.trim() && !images.length)} onClick=${send}>
      ${a.busy ? 'Wird gesendet …' : 'Feedback senden'}</button></div>
    <${Msg} msg=${a.msg} />
  </section>`;
}
