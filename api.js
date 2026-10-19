/* =====================================================================
   SplitSub API client (shared by the customer app and the admin app)
   Talks to Supabase over HTTPS:
     /auth/v1       sign up, sign in, email codes, password reset
     /rest/v1/rpc   database functions (every rule is checked there)
     /storage/v1    host proof uploads (private bucket)
     /functions/v1  Flutterwave payment functions
   No secrets live here. Only the user's own login session is kept in
   the browser so they stay signed in.
   ===================================================================== */
(function () {
  const cfg = window.SUBSPLIT_CONFIG || {};
  const BASE = (cfg.SUPABASE_URL || '').replace(/\/+$/, '');
  const KEY = cfg.SUPABASE_PUBLISHABLE_KEY || '';
  const STORE = 'subsplit-session';
  let session = null;
  try { session = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (e) { session = null; }

  function save(s) {
    session = s;
    try { if (s) localStorage.setItem(STORE, JSON.stringify(s)); else localStorage.removeItem(STORE); } catch (e) { /* private mode */ }
  }
  function claims(token) {
    try { return JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch (e) { return {}; }
  }
  function toSession(j) {
    const c = claims(j.access_token);
    return {
      access_token: j.access_token, refresh_token: j.refresh_token,
      expires_at: Number(j.expires_at) || c.exp || Math.floor(Date.now() / 1000) + (Number(j.expires_in) || 3600),
      user: j.user && j.user.id ? { id: j.user.id, email: j.user.email } : { id: c.sub, email: c.email }
    };
  }

  class ApiError extends Error {
    constructor(message, status, code) { super(message); this.status = status; this.code = code; }
  }
  function friendly(msg, status) {
    const m = String(msg || '');
    if (/Invalid login credentials/i.test(m)) return 'Wrong email or password.';
    if (/Email not confirmed/i.test(m)) return 'Your email is not confirmed yet. Enter the code we sent you.';
    if (/Token has expired or is invalid|otp_expired|otp.*(invalid|expired)/i.test(m)) return 'That code is wrong or has expired. Tap "Send a new code" and try again.';
    if (/already registered|already been registered|already exists/i.test(m)) return 'An account with this email already exists. Sign in instead.';
    if (/Password should|weak password/i.test(m)) return 'Use a stronger password (at least 8 characters, letters and numbers).';
    if (/rate limit|too many|only request this after/i.test(m)) return 'Please wait a minute before trying again.';
    if (/JWT expired|invalid JWT|bad_jwt/i.test(m)) return 'Your session expired. Please sign in again.';
    if (/^permission denied/i.test(m)) return 'You are not allowed to do that.';
    if (status === 0) return 'No internet connection. Check your network and try again.';
    return m || 'Something went wrong. Please try again.';
  }

  async function call(path, opts) {
    const o = Object.assign({ method: 'POST', auth: true, json: true, headers: {} }, opts || {});
    const h = Object.assign({ apikey: KEY }, o.headers);
    if (o.json && o.body !== undefined) h['Content-Type'] = 'application/json';
    if (o.auth && session && session.access_token) h.Authorization = 'Bearer ' + session.access_token;
    let res;
    try {
      res = await fetch(BASE + path, { method: o.method, headers: h, body: o.body === undefined ? undefined : (o.json ? JSON.stringify(o.body) : o.body) });
    } catch (e) { throw new ApiError(friendly('', 0), 0); }
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = text; }
    if (!res.ok) {
      const d = data && typeof data === 'object' ? data : {};
      throw new ApiError(friendly(d.message || d.msg || d.error_description || d.error || res.statusText, res.status), res.status, d.code || d.error_code);
    }
    return data;
  }
  async function refreshIfNeeded(force) {
    if (!session) return;
    if (!force && session.expires_at - 60 > Date.now() / 1000) return;
    try {
      const j = await call('/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: session.refresh_token }, auth: false });
      save(toSession(j));
    } catch (e) { if (e.status >= 400 && e.status < 500) save(null); }
  }
  async function authed(path, opts) {
    await refreshIfNeeded(false);
    try { return await call(path, opts); }
    catch (e) {
      if (e.status === 401 && session) { await refreshIfNeeded(true); if (session) return call(path, opts); }
      throw e;
    }
  }
  const here = () => location.origin + location.pathname;
  const enc = p => p.split('/').map(encodeURIComponent).join('/');

  window.API = {
    configured: !!(BASE && KEY),
    ApiError,
    get user() { return session ? session.user : null; },
    // After an email-confirm or password-reset link, Supabase returns to the site with #access_token=...
    consumeAuthRedirect() {
      const h = new URLSearchParams(location.hash.replace(/^#/, ''));
      if (!h.get('access_token') && !h.get('error_description')) return null;
      history.replaceState(null, '', location.pathname + location.search);
      if (h.get('error_description')) return { error: h.get('error_description') };
      save(toSession({ access_token: h.get('access_token'), refresh_token: h.get('refresh_token'),
                       expires_at: h.get('expires_at'), expires_in: h.get('expires_in') }));
      return { type: h.get('type') || 'signin' };
    },
    // Sign-up sends a 6-digit code by email. The account is only active after the code is checked (verifyCode).
    async signUp(d) {
      const j = await call('/auth/v1/signup?redirect_to=' + encodeURIComponent(here()),
        { body: { email: d.email, password: d.password, data: { full_name: d.full_name, phone: d.phone, referral_code: d.referral_code || '' } }, auth: false });
      if (j && j.access_token) { save(toSession(j)); return { confirm: false }; }
      return { confirm: true };
    },
    // type: 'signup' (new account) or 'recovery' (forgot password). Signs the person in when the code is right.
    async verifyCode(email, token, type) {
      const j = await call('/auth/v1/verify', { body: { type: type || 'signup', email, token: String(token).replace(/\s+/g, '') }, auth: false });
      save(toSession(j));
    },
    resendCode(email) { return call('/auth/v1/resend', { body: { type: 'signup', email }, auth: false }); },
    async signIn(email, password) {
      const j = await call('/auth/v1/token?grant_type=password', { body: { email, password }, auth: false });
      save(toSession(j));
    },
    async signOut() { try { await call('/auth/v1/logout', { body: {} }); } catch (e) { /* already signed out */ } save(null); },
    forgetSession() { save(null); },
    // Sends a 6-digit code (not a link). Finish with verifyCode(email, code, 'recovery') then updatePassword().
    resetPassword(email) { return call('/auth/v1/recover?redirect_to=' + encodeURIComponent(here()), { body: { email }, auth: false }); },
    updatePassword(password) { return authed('/auth/v1/user', { method: 'PUT', body: { password } }); },
    rpc(fn, args) { return authed('/rest/v1/rpc/' + fn, { body: args || {} }); },
    fn(name, body) { return authed('/functions/v1/' + name, { body: body || {} }); },
    upload(bucket, path, file, upsert) {
      return authed('/storage/v1/object/' + bucket + '/' + enc(path),
        { body: file, json: false, headers: { 'Content-Type': file.type || 'application/octet-stream', 'x-upsert': upsert === false ? 'false' : 'true' } });
    },
    publicUrl(bucket, path) { return BASE + '/storage/v1/object/public/' + bucket + '/' + enc(path); },
    async signedUrl(bucket, path, seconds) {
      const j = await authed('/storage/v1/object/sign/' + bucket + '/' + enc(path), { body: { expiresIn: seconds || 600 } });
      const u = j.signedURL || j.signedUrl || '';
      return /^https?:/.test(u) ? u : BASE + '/storage/v1' + u;
    }
  };
})();
