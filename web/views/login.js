import { html, useState } from '../vendor/preact-htm.js';
import { sb, useAction, Msg } from '../lib.js';

export function Login() {
  const [mode, setMode] = useState('login');   // login | signup | magic
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const a = useAction();
  const redirect = location.origin + location.pathname;

  const submit = (e) => {
    e.preventDefault();
    a.run(async () => {
      if (mode === 'login') {
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) throw new Error(error.message === 'Invalid login credentials' ? 'E-Mail oder Passwort falsch.' : error.message);
      } else if (mode === 'signup') {
        const { data, error } = await sb.auth.signUp({
          email, password, options: { data: { display_name: name || email.split('@')[0] }, emailRedirectTo: redirect },
        });
        if (error) throw new Error(error.message);
        if (!data.session) a.setMsg({ ok: true, text: 'Fast geschafft: Bitte bestätige die E-Mail, die wir dir geschickt haben.' });
      } else {
        const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: redirect } });
        if (error) throw new Error(error.message);
        a.setMsg({ ok: true, text: 'Link verschickt – schau in dein Postfach.' });
      }
    });
  };

  return html`<main class="wrap narrow">
    <div class="brand"><img src="logo.svg" alt="" class="logo-img" /> UCI Fantasy</div>
    <div class="card">
      <div class="seg" role="tablist">
        ${[['login', 'Anmelden'], ['signup', 'Registrieren'], ['magic', 'Magic Link']].map(([k, l]) =>
          html`<button type="button" class=${mode === k ? 'active' : ''} onClick=${() => { setMode(k); a.setMsg(null); }}>${l}</button>`)}
      </div>
      <button type="button" class="google" disabled=${a.busy}
        onClick=${() => a.run(async () => {
          const { error } = await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: redirect } });
          if (error) throw new Error(error.message);
        })}>
        <svg viewBox="0 0 48 48" width="18" height="18" aria-hidden="true"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>
        Mit Google anmelden</button>
      <div class="divider"><span>oder mit E-Mail</span></div>
      <form onSubmit=${submit} class="stack">
        ${mode === 'signup' && html`<label>Name<input value=${name} onInput=${(e) => setName(e.target.value)} autocomplete="nickname" /></label>`}
        <label>E-Mail<input type="email" required value=${email} onInput=${(e) => setEmail(e.target.value)} autocomplete="email" /></label>
        ${mode !== 'magic' && html`<label>Passwort<input type="password" required minlength="6" value=${password}
            onInput=${(e) => setPassword(e.target.value)} autocomplete=${mode === 'signup' ? 'new-password' : 'current-password'} /></label>`}
        <button class="primary" disabled=${a.busy}>
          ${mode === 'login' ? 'Anmelden' : mode === 'signup' ? 'Konto anlegen' : 'Link schicken'}
        </button>
        <${Msg} msg=${a.msg} />
      </form>
    </div>
    <p class="muted small center">Mit einem Einladungslink kommst du nach der Anmeldung direkt in die Liga.</p>
  </main>`;
}
