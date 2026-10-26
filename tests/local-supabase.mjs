// =====================================================================
// LOCAL TEST SERVER (not for production). Imitates the parts of Supabase
// the apps use — Auth, /rest/v1/rpc (real Postgres + real roles/RLS),
// Storage, and Edge Functions (runs the REAL backend/functions/*.ts code) —
// plus a fake Flutterwave checkout. Lets us test both apps end to end.
//   node tests/local-supabase.mjs   (needs a local Postgres, see README)
// =====================================================================
import http from 'node:http';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = +(process.env.PORT || 8787), BASE = `http://localhost:${PORT}`;
const PGHOST = process.env.PGHOST, PGPORT = process.env.PGPORT || '5432', PGDB = process.env.PGDATABASE || 'e2e';
const SERVICE_KEY = 'service-role-local', PUBLISHABLE = 'publishable-local', FLW_SECRET = 'FLWSECK_TEST-local', FLW_HASH = 'hash-local';

// ---------- Postgres ----------
function psql(sql) {
  return new Promise(res => execFile('psql', ['-h', PGHOST, '-p', PGPORT, '-U', 'postgres', '-d', PGDB, '-X', '-q', '-t', '-A',
    '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-c', sql], { maxBuffer: 64 * 1024 * 1024 },
    (err, out, errOut) => res({ ok: !err, out: (out || '').trim(), err: (errOut || '').trim() })));
}
const q = v => v === null || v === undefined ? 'NULL' : "'" + String(typeof v === 'object' ? JSON.stringify(v) : v).replace(/'/g, "''") + "'";
const retTypes = {};
async function retType(fn) {
  if (!retTypes[fn] || retTypes[fn] === 'missing') { const r = await psql(`select prorettype::regtype from pg_proc where proname = ${q(fn)} and pronamespace = 'public'::regnamespace limit 1`); retTypes[fn] = r.out || 'missing'; }
  return retTypes[fn];
}
function pgError(errText) {
  const line = errText.split('\n').find(l => l.startsWith('ERROR:')) || errText;
  const m = line.match(/^ERROR:\s+([0-9A-Z]{5}):\s+(.*)$/);
  return m ? { code: m[1], message: m[2] } : { code: 'XX000', message: line.replace(/^ERROR:\s+/, '') };
}
function asRole(role, sub) {
  return `begin; set local role ${role}; set local "request.jwt.claim.sub" = ${q(sub || '')};`;
}

// ---------- tiny JWT (unsigned, test only) ----------
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
function makeSession(u) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  return { access_token: `${b64({ alg: 'none' })}.${b64({ sub: u.id, email: u.email, role: 'authenticated', exp })}.x`, token_type: 'bearer',
           expires_in: 3600, expires_at: exp, refresh_token: 'rt-' + u.id, user: { id: u.id, email: u.email } };
}
function whoFromAuth(req) {
  const h = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!h) return { role: 'anon' };
  if (h === SERVICE_KEY) return { role: 'service_role' };
  try { const p = JSON.parse(Buffer.from(h.split('.')[1], 'base64url')); if (p.exp > Date.now() / 1000) return { role: 'authenticated', sub: p.sub, email: p.email }; } catch (e) {}
  return { role: 'invalid' };
}

// ---------- Edge Functions: load the real code with a Deno shim ----------
const ENV = { SUPABASE_URL: BASE, SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY, FLUTTERWAVE_SECRET_KEY: FLW_SECRET, FLUTTERWAVE_WEBHOOK_HASH: FLW_HASH,
              FLUTTERWAVE_API_BASE: BASE + '/flw/v3', SITE_URL: BASE + '/',
              // bulk messages: fake providers (see /fake/* below)
              RESEND_API_KEY: 're_local', RESEND_BASE_URL: BASE + '/fake/resend', EMAIL_FROM: 'SplitSub <hello@splitsub.app>',
              TERMII_API_KEY: 'tm_local', TERMII_SENDER_ID: 'SplitSub', TERMII_BASE_URL: BASE + '/fake/termii',
              WHATSAPP_TOKEN: 'wa_local', WHATSAPP_PHONE_NUMBER_ID: '123456', WHATSAPP_TEMPLATE: 'splitsub_update', WHATSAPP_GRAPH_URL: BASE + '/fake/graph',
              BULK_GAP_MS: '0' };
const FUNCS = {};
globalThis.Deno = { env: { get: k => ENV[k] }, serve: h => { FUNCS.__last = h; } };
for (const name of ['payments-init', 'payments-verify', 'flutterwave-webhook', 'admin-delete-user', 'bulk-send']) {
  await import(pathToFileURL(path.join(ROOT, 'backend/functions', name, 'index.ts')).href);
  FUNCS[name] = FUNCS.__last;
}

// ---------- fake Paystack ----------
const FLW = {};  // tx_ref -> tx
const UNCONFIRMED = new Set(), RESENDS = [], SENT = [];
const storageFiles = {};

function send(res, status, body, headers = {}) {
  const isStr = typeof body === 'string' || Buffer.isBuffer(body);
  res.writeHead(status, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*',
                          'Content-Type': isStr ? (headers['Content-Type'] || 'text/html; charset=utf-8') : 'application/json', ...headers });
  res.end(isStr ? body : JSON.stringify(body));
}
const readBody = req => new Promise(r => { const c = []; req.on('data', d => c.push(d)); req.on('end', () => r(Buffer.concat(c))); });
const STATIC = { '/': 'frontend/index.html', '/index.html': 'frontend/index.html', '/api.js': 'frontend/api.js', '/logo-mark.svg': 'frontend/logo-mark.svg',
                 '/logo.svg': 'frontend/logo.svg', '/admin/': 'admin/index.html', '/admin/index.html': 'admin/index.html' };
const MIME = { html: 'text/html; charset=utf-8', js: 'text/javascript', svg: 'image/svg+xml' };

http.createServer(async (req, res) => {
  const url = new URL(req.url, BASE), p = url.pathname;
  try {
    if (req.method === 'OPTIONS') return send(res, 204, '');
    // static apps
    if (p === '/config.js') return send(res, 200, `window.SUBSPLIT_CONFIG = { SUPABASE_URL: '${BASE}', SUPABASE_PUBLISHABLE_KEY: '${PUBLISHABLE}' };`, { 'Content-Type': 'text/javascript' });
    if (p === '/admin') return send(res, 301, '', { Location: '/admin/' });
    if (STATIC[p] && req.method === 'GET') { const f = STATIC[p]; return send(res, 200, fs.readFileSync(path.join(ROOT, f)), { 'Content-Type': MIME[f.split('.').pop()] }); }
    if (p.startsWith('/rest/') || p.startsWith('/auth/') || p.startsWith('/storage/') || p.startsWith('/functions/')) {
      if (req.headers.apikey !== PUBLISHABLE && req.headers.apikey !== SERVICE_KEY && !p.startsWith('/storage/v1/object/sign-local/')) return send(res, 401, { message: 'Invalid API key' });
    }
    const body = await readBody(req);
    const json = () => { try { return JSON.parse(body.toString() || '{}'); } catch (e) { return {}; } };

    // ----- Auth -----
    if (p === '/auth/v1/signup') {
      const b = json();
      const codeMode = /@code\.test$/i.test(String(b.email || ''));
      if (!b.email || !b.password || b.password.length < 6) return send(res, 422, { msg: 'Password should be at least 6 characters' });
      const r = await psql(`insert into auth.users (email, raw_user_meta_data, test_password) values (${q(b.email.toLowerCase())}, ${q(b.data || {})}, ${q(b.password)}) returning id`);
      if (!r.ok) return send(res, 422, { msg: 'User already registered' });
      if (codeMode) { UNCONFIRMED.add(b.email.toLowerCase()); return send(res, 200, { id: r.out, email: b.email.toLowerCase(), confirmation_sent_at: new Date().toISOString() }); }
      return send(res, 200, makeSession({ id: r.out, email: b.email.toLowerCase() }));
    }
    // 6-digit email code flow (the real Supabase sends the code by email; here it is always 123456)
    if (p === '/auth/v1/verify') {
      const b = json(), em = String(b.email || '').toLowerCase();
      if (b.token !== '123456' || !['signup', 'recovery', 'email'].includes(b.type)) return send(res, 403, { code: 'otp_expired', msg: 'Token has expired or is invalid' });
      const r = await psql(`select id from auth.users where email = ${q(em)}`);
      if (!r.out) return send(res, 403, { code: 'otp_expired', msg: 'Token has expired or is invalid' });
      UNCONFIRMED.delete(em);
      return send(res, 200, makeSession({ id: r.out, email: em }));
    }
    if (p === '/auth/v1/resend') { RESENDS.push(String(json().email || '').toLowerCase()); return send(res, 200, {}); }
    if (p === '/auth/v1/token') {
      const b = json();
      if (url.searchParams.get('grant_type') === 'refresh_token') {
        const id = String(b.refresh_token || '').replace(/^rt-/, '');
        const r = await psql(`select email from auth.users where id = ${q(id)}`);
        return r.out ? send(res, 200, makeSession({ id, email: r.out })) : send(res, 400, { error_description: 'Invalid Refresh Token' });
      }
      if (UNCONFIRMED.has(String(b.email || '').toLowerCase())) return send(res, 400, { error_code: 'email_not_confirmed', msg: 'Email not confirmed' });
      const r = await psql(`select id from auth.users where email = ${q(String(b.email || '').toLowerCase())} and test_password = ${q(b.password)} and not coalesce(banned, false)`);
      return r.out ? send(res, 200, makeSession({ id: r.out, email: b.email.toLowerCase() })) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
    }
    if (p === '/auth/v1/user') {
      const w = whoFromAuth(req);
      if (w.role !== 'authenticated') return send(res, 401, { msg: 'invalid JWT' });
      if (req.method === 'PUT') { const b = json(); if (b.password) await psql(`update auth.users set test_password = ${q(b.password)} where id = ${q(w.sub)}`); }
      return send(res, 200, { id: w.sub, email: w.email });
    }
    if (p === '/auth/v1/logout') return send(res, 204, '');
    if (p === '/auth/v1/recover') return send(res, 200, {});

    // ----- Auth admin + table access used by the admin-delete-user function (service role only) -----
    {
      const w = whoFromAuth(req), um = p.match(/^\/auth\/v1\/admin\/users\/([0-9a-f-]{36})$/), wm = p.match(/^\/rest\/v1\/wallet_accounts$/);
      if (um || wm) {
        if (w.role !== 'service_role') return send(res, 401, { message: 'service role only' });
        if (um && req.method === 'DELETE') { const r = await psql(`delete from auth.users where id = ${q(um[1])}`); return r.ok ? send(res, 200, {}) : send(res, 500, { message: r.err }); }
        if (um && req.method === 'PUT') { const bj = json(); const r = await psql(`update auth.users set email = ${q(bj.email)}, banned = true where id = ${q(um[1])}`); return r.ok ? send(res, 200, {}) : send(res, 500, { message: r.err }); }
        if (wm && req.method === 'DELETE') { const id = (url.searchParams.get('owner_id') || '').replace(/^eq\./, ''); const r = await psql(`delete from public.wallet_accounts where owner_id = ${q(id)}`); return r.ok ? send(res, 204, '') : send(res, 409, { message: r.err }); }
      }
    }

    // ----- Database functions (PostgREST /rpc) -----
    if (p.startsWith('/rest/v1/rpc/')) {
      const fn = p.split('/').pop(), w = whoFromAuth(req);
      if (w.role === 'invalid') return send(res, 401, { code: 'PGRST301', message: 'JWT expired' });
      if (!/^[a-z_][a-z0-9_]*$/.test(fn)) return send(res, 404, { message: 'Not found' });
      const rt = await retType(fn);
      if (rt === 'missing') return send(res, 404, { code: 'PGRST202', message: `Could not find the function public.${fn}` });
      const args = Object.entries(json()).map(([k, v]) => `${k} => ${q(v)}`).join(', ');
      const call = `public.${fn}(${args})`;
      const sql = asRole(w.role, w.sub) + (rt === 'void' ? ` select ${call}; select 'null';` : ` select coalesce(to_json(${call})::text, 'null');`) + ' commit;';
      const r = await psql(sql);
      if (!r.ok) { const e = pgError(r.err); return send(res, e.code === '42501' ? (w.role === 'anon' ? 401 : 403) : e.code === '28000' ? 403 : 400, e); }
      const lines = r.out.split('\n'); return send(res, 200, lines[lines.length - 1] || 'null', { 'Content-Type': 'application/json' });
    }

    // ----- Storage (policies are the real ones from 002_storage.sql) -----
    let m;
    if ((m = p.match(/^\/storage\/v1\/object\/sign\/([^/]+)\/(.+)$/))) {
      const w = whoFromAuth(req), name = decodeURIComponent(m[2]);
      const r = await psql(asRole(w.role === 'authenticated' ? 'authenticated' : 'anon', w.sub) + ` select count(*) from storage.objects where bucket_id = ${q(m[1])} and name = ${q(name)}; commit;`);
      if (!r.ok || r.out.split('\n').pop() !== '1') return send(res, 400, { message: 'Object not found' });
      return send(res, 200, { signedURL: `/object/sign-local/${m[1]}/${m[2]}?token=t` });
    }
    if ((m = p.match(/^\/storage\/v1\/object\/sign-local\/([^/]+)\/(.+)$/))) {
      const f = storageFiles[m[1] + '/' + decodeURIComponent(m[2])];
      return f ? send(res, 200, f.data, { 'Content-Type': f.type }) : send(res, 404, 'missing');
    }
    if ((m = p.match(/^\/storage\/v1\/object\/([^/]+)\/(.+)$/)) && req.method === 'POST') {
      const w = whoFromAuth(req), name = decodeURIComponent(m[2]);
      if (body.length > 5 * 1024 * 1024) return send(res, 413, { message: 'The object exceeded the maximum allowed size' });
      const r = await psql(asRole('authenticated', w.sub) + ` insert into storage.objects (bucket_id, name, owner) values (${q(m[1])}, ${q(name)}, ${q(w.sub)})
        on conflict (bucket_id, name) do update set created_at = now(); commit;`);
      if (!r.ok) return send(res, 403, { message: 'new row violates row-level security policy' });
      storageFiles[m[1] + '/' + name] = { data: body, type: req.headers['content-type'] };
      return send(res, 200, { Key: m[1] + '/' + name });
    }

    // ----- Edge Functions (real code) -----
    if ((m = p.match(/^\/functions\/v1\/([a-z-]+)$/)) && FUNCS[m[1]]) {
      const r = await FUNCS[m[1]](new Request(BASE + p, { method: req.method, headers: req.headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body }));
      return send(res, r.status, Buffer.from(await r.arrayBuffer()), { 'Content-Type': r.headers.get('content-type') || 'application/json' });
    }

    // ----- Fake message providers (Resend, Termii, WhatsApp Cloud API) -----
    if (p === '/fake/resend/emails' && req.method === 'POST') {
      if (req.headers.authorization !== 'Bearer re_local') return send(res, 401, { message: 'bad key' });
      const b = json(); const to = (b.to || [])[0] || '';
      if (/bounce/.test(to)) return send(res, 422, { message: 'Invalid recipient' });
      SENT.push({ channel: 'EMAIL', to, subject: b.subject, text: b.text }); return send(res, 200, { id: 'em_' + SENT.length });
    }
    if (p === '/fake/termii/api/sms/send' && req.method === 'POST') {
      const b = json();
      if (b.api_key !== 'tm_local') return send(res, 401, { message: 'Unauthorized' });
      if (/0000$/.test(b.to)) return send(res, 400, { message: 'Invalid phone number' });
      SENT.push({ channel: 'SMS', to: b.to, from: b.from, text: b.sms }); return send(res, 200, { code: 'ok', message_id: 'sms_' + SENT.length });
    }
    if (p === '/fake/graph/123456/messages' && req.method === 'POST') {
      if (req.headers.authorization !== 'Bearer wa_local') return send(res, 401, { error: { message: 'Invalid OAuth access token' } });
      const b = json();
      if (/9999$/.test(b.to)) return send(res, 400, { error: { message: 'Recipient phone number not on WhatsApp' } });
      SENT.push({ channel: 'WHATSAPP', to: b.to, template: b.template && b.template.name, text: b.template ? b.template.components[0].parameters[0].text : b.text.body });
      return send(res, 200, { messages: [{ id: 'wamid.' + SENT.length }] });
    }
    if (p === '/test/sent') return send(res, 200, SENT);
    // GitHub Pages serves 404.html for unknown paths (creator links like /kemi)
    if (req.method === 'GET' && /^\/[A-Za-z0-9]{3,12}\/?$/.test(p)) return send(res, 404, fs.readFileSync(path.join(ROOT, 'frontend/404.html')));

    // ----- Fake Flutterwave -----
    if (p === '/flw/v3/payments') {
      if (req.headers.authorization !== 'Bearer ' + FLW_SECRET) return send(res, 401, { status: 'error', message: 'Invalid key' });
      const b = json();
      FLW[b.tx_ref] = { ...b, status: 'pending', id: Math.floor(Math.random() * 1e9) };
      return send(res, 200, { status: 'success', data: { link: `${BASE}/flw/checkout/${b.tx_ref}` } });
    }
    if ((m = p.match(/^\/flw\/checkout\/(.+)$/))) {
      const t = FLW[m[1]]; if (!t) return send(res, 404, 'Unknown');
      return send(res, 200, `<!doctype html><meta name="viewport" content="width=device-width"><body style="font:16px system-ui;padding:24px;background:#f5a623;color:#111">
        <h2>Flutterwave (TEST)</h2><p>${t.customer.email}</p><p style="font-size:28px"><b>NGN ${t.amount.toLocaleString()}</b></p>
        <a id="pay" href="/flw/pay/${m[1]}?ok=1" style="display:block;background:#111;color:#fff;padding:14px;border-radius:8px;text-align:center;font-weight:700;text-decoration:none">Pay</a>
        <p><a id="cancel" href="/flw/pay/${m[1]}?ok=0" style="color:#111">Cancel payment</a></p>`);
    }
    if ((m = p.match(/^\/flw\/pay\/(.+)$/))) {
      const t = FLW[m[1]]; const ok = url.searchParams.get('ok') === '1'; t.status = ok ? 'successful' : 'cancelled';
      const cb = new URL(t.redirect_url); cb.searchParams.set('status', ok ? 'successful' : 'cancelled'); cb.searchParams.set('tx_ref', m[1]);
      if (ok) cb.searchParams.set('transaction_id', String(t.id));
      return send(res, 302, '', { Location: cb.toString() });
    }
    if (p === '/flw/v3/transactions/verify_by_reference') {
      if (req.headers.authorization !== 'Bearer ' + FLW_SECRET) return send(res, 401, { status: 'error' });
      const t = FLW[url.searchParams.get('tx_ref')];
      if (!t || t.status === 'pending') return send(res, 404, { status: 'error', message: 'No transaction was found for this id' });
      return send(res, 200, { status: 'success', data: { status: t.status, amount: t.amount, currency: t.currency ?? 'NGN', id: t.id, payment_type: 'card', tx_ref: t.tx_ref, meta: t.meta } });
    }
    // test helper: change what the fake Flutterwave reports for a transaction (under-payment, wrong currency, failed...)
    if ((m = p.match(/^\/test\/flw\/(.+)$/)) && req.method === 'POST') {
      const t = FLW[m[1]]; if (!t) return send(res, 404, { message: 'unknown transaction' });
      Object.assign(t, json()); return send(res, 200, { ok: true });
    }
    // test helper: fire a Flutterwave webhook at the real webhook function
    if ((m = p.match(/^\/test\/webhook\/(.+)$/))) {
      const raw = JSON.stringify({ event: 'charge.completed', data: { tx_ref: m[1], status: 'successful' } });
      const r = await FUNCS['flutterwave-webhook'](new Request(BASE + '/functions/v1/flutterwave-webhook', { method: 'POST', headers: { 'verif-hash': url.searchParams.get('bad') ? 'wrong' : FLW_HASH }, body: raw }));
      return send(res, r.status, await r.text(), { 'Content-Type': 'text/plain' });
    }
    send(res, 404, { message: 'Not found: ' + p });
  } catch (e) { console.error(e); send(res, 500, { message: String(e.message || e) }); }
}).listen(PORT, () => console.log('local supabase on ' + BASE));
