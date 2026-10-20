// 50x stress test of the REAL payment Edge Function code (payments-init, payments-verify, flutterwave-webhook)
// running inside tests/local-supabase.mjs with a fake Flutterwave.
// What it proves: money only reaches a wallet when Flutterwave confirms a real NGN payment, only for the
// amount actually paid, and only once. Forged webhooks, replays, unpaid or cancelled payments, tampered
// amounts and wrong currencies never add money.
//   PGDATABASE=sf PORT=8790 node --experimental-strip-types tests/local-supabase.mjs &
//   PGDATABASE=sf PORT=8790 node tests/stress_functions.mjs
import { execFileSync } from 'node:child_process';
const PORT = process.env.PORT || 8790, B = `http://localhost:${PORT}`, DB = process.env.PGDATABASE || 'sf', N = +(process.env.N || 50);
const KEY = 'publishable-local', HASH = 'hash-local';
const sql = s => execFileSync('psql', ['-h', process.env.PGHOST, '-p', process.env.PGPORT, '-U', 'postgres', '-d', DB, '-X', '-q', '-t', '-A', '-c', s]).toString().trim();
const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail });

async function call(path, { method = 'POST', token, body, headers = {} } = {}) {
  const r = await fetch(B + path, { method, headers: { apikey: KEY, 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
const signup = async (email, name) => (await call('/auth/v1/signup', { body: { email, password: 'password123', data: { full_name: name } } })).body;
const wallet = email => +sql(`select coalesce((select a.balance_kobo from wallet_accounts a join profiles p on p.id = a.owner_id where p.email = '${email}' and a.kind = 'WALLET'), 0)`);
const topups = email => +sql(`select count(*) from wallet_transactions w join profiles p on p.id = w.user_id where p.email = '${email}' and w.type = 'TOP_UP'`);
const payments = () => +sql(`select count(*) from payments`);
const init = (token, body) => call('/functions/v1/payments-init', { token, body });
const verify = ref => call('/functions/v1/payments-verify', { body: { reference: ref } });
// the webhook body always claims a big successful payment; the function must ignore it and ask Flutterwave
const hook = (ref, hash = HASH) => call('/functions/v1/flutterwave-webhook', { headers: { 'verif-hash': hash },
  body: { event: 'charge.completed', data: { tx_ref: ref, status: 'successful', amount: 9999999, currency: 'NGN' } } });
const flw = (ref, patch) => call('/test/flw/' + ref, { body: patch });          // change what fake Flutterwave reports
const pay = ref => fetch(B + '/flw/pay/' + ref + '?ok=1', { redirect: 'manual' });  // the customer really pays
const cancel = ref => fetch(B + '/flw/pay/' + ref + '?ok=0', { redirect: 'manual' });
const randRef = () => 'SS-' + Math.random().toString(36).slice(2, 12).toUpperCase() + Math.random().toString(36).slice(2, 8).toUpperCase();
const all = async (n, f) => { const out = []; for (let i = 0; i < n; i++) out.push(await f(i)); return out; };

// ---------- setup ----------
const U = await signup('payer@stress.ng', 'Paying User'), V = await signup('attacker@stress.ng', 'Eve Attacker');
check('Setup: two users signed up', U.access_token && V.access_token);
const host = await signup('host@stress.ng', 'Hannah Host');
const L = sql(`with p as (select sp.id from service_plans sp join services s on s.id = sp.service_id where s.name = 'Netflix'),
  l as (insert into listings (host_id, plan_id, markup_pct, seats_offered, status, agreement_accepted_at)
        select '${host.user.id}', p.id, 30, 4, 'DRAFT', now() from p returning id),
  h as (insert into host_proofs (listing_id, host_id, service_name, file_path, status) select l.id, '${host.user.id}', 'Netflix', 'x', 'APPROVED' from l)
  select id from l`);
sql(`insert into listing_access (listing_id, details) values ('${L}', 'Email: n@x.ng Pass: S3cret')`);
sql(`update listings set status = 'LIVE' where id = '${L}'`);
const SEAT = 276300 + 20000;   // N8,500 +30% / 4 = N2,763 seat + N200 buyer fee

// ---------- F1-F4 payments-init ----------
{ const before = payments();
  const r = await all(N, () => init(undefined, { purpose: 'TOPUP', amount_kobo: 100000 }));
  check(`F1 payments-init without login refused ${N}/${N}`, r.every(x => x.status === 401) && payments() === before, r.map(x => x.status).join(','));
}
{ const before = payments(), expired = Buffer.from(JSON.stringify({ alg: 'none' })).toString('base64url') + '.' +
    Buffer.from(JSON.stringify({ sub: U.user.id, role: 'authenticated', exp: 1 })).toString('base64url') + '.x';
  const bad = ['abc', 'Bearer', 'x.y.z', expired, 'eyJhbGciOiJIUzI1NiJ9.e30.forged'];
  const r = await all(N, i => init(bad[i % bad.length], { purpose: 'TOPUP', amount_kobo: 100000 }));
  check(`F2 payments-init with fake or expired login refused ${N}/${N}`, r.every(x => x.status === 401) && payments() === before, r.map(x => x.status).join(','));
}
{ const before = +sql(`select count(*) from payments where status = 'PENDING'`);
  const amounts = [0, -500, 50, 99, 1e13, 'abc', null, 9.99, -1e9, '100000; drop table payments'];
  const r = await all(N, i => init(U.access_token, { purpose: 'TOPUP', amount_kobo: amounts[i % amounts.length] }));
  check(`F3 top-ups below the minimum, above the maximum, negative or junk refused ${N}/${N}`,
    r.every(x => x.status >= 400 && !x.body.reference) && +sql(`select count(*) from payments where status = 'PENDING'`) === before, JSON.stringify(r[0].body));
}
{ const fakeAmounts = [1, 100, 2000, 999999999, -5, 0];
  const r = await all(N, i => init(U.access_token, { purpose: 'SEAT', listing_id: L, amount_kobo: fakeAmounts[i % fakeAmounts.length], contact: '' }));
  const refs = r.map(x => x.body.reference).filter(Boolean);
  const amounts = refs.length ? sql(`select string_agg(distinct amount_kobo::text, ',') from payments where reference in (${refs.map(x => `'${x}'`).join(',')})`) : '';
  check(`F4 seat payments always use the server price (N2,963), whatever the browser sends ${N}/${N}`, refs.length === N && amounts === String(SEAT), `${refs.length} refs, amounts=${amounts}`);
  const bogus = await all(10, () => init(U.access_token, { purpose: 'SEAT', listing_id: '11111111-1111-4111-8111-111111111111' }));
  check('F4b seat payment for a listing that does not exist refused 10/10', bogus.every(x => x.status >= 400 && !x.body.reference));
  sql(`update payments set status = 'ABANDONED' where purpose = 'SEAT' and status = 'PENDING'`);   // tidy: these were never paid
}

// ---------- F5-F10 nothing paid = nothing credited ----------
const w0 = wallet('payer@stress.ng'), t0 = topups('payer@stress.ng');
{ const r = await all(N, () => verify(randRef()));
  check(`F5 verify with made-up references credits nothing ${N}/${N}`, r.every(x => x.body.status === 'PENDING') && wallet('payer@stress.ng') === w0);
}
const unpaid = (await all(N, () => init(U.access_token, { purpose: 'TOPUP', amount_kobo: 500000 }))).map(x => x.body.reference);
check(`Setup: ${N} real top-ups started but never paid`, unpaid.filter(Boolean).length === N);
{ const r = await all(N, i => verify(unpaid[i]));
  check(`F6 verify on payments the user never made credits nothing ${N}/${N}`, r.every(x => x.body.status === 'PENDING') && wallet('payer@stress.ng') === w0);
}
{ const r = await all(N, i => hook(unpaid[i], i % 2 ? 'wrong-hash' : ''));
  check(`F7 webhooks with a wrong or missing secret hash rejected ${N}/${N}`, r.every(x => x.status === 401) && wallet('payer@stress.ng') === w0, r.map(x => x.status).join(','));
}
{ const r = await all(N, i => hook(unpaid[i]));
  check(`F8 webhooks WITH the right hash but for unpaid payments credit nothing ${N}/${N} (re-checked with Flutterwave)`,
    r.every(x => x.status === 200) && wallet('payer@stress.ng') === w0 && topups('payer@stress.ng') === t0);
}
{ const r = await all(N, () => hook(randRef()));
  check(`F9 webhooks with the right hash for made-up references credit nothing ${N}/${N}`, r.every(x => x.status === 200) && wallet('payer@stress.ng') === w0);
}
{ for (const ref of unpaid) await cancel(ref);
  const r = await all(N, i => verify(unpaid[i])), h = await all(N, i => hook(unpaid[i]));
  check(`F10 cancelled payments credit nothing, even with webhook replays ${N}/${N}`,
    r.every(x => x.body.status === 'CANCELLED') && h.every(x => x.status === 200) && wallet('payer@stress.ng') === w0 &&
    +sql(`select count(*) from payments where reference in (${unpaid.map(x => `'${x}'`).join(',')}) and status = 'ABANDONED'`) === N);
}

// ---------- F11-F12 tampered amounts and currencies ----------
{ const refs = (await all(N, () => init(U.access_token, { purpose: 'TOPUP', amount_kobo: 500000 }))).map(x => x.body.reference);
  for (const ref of refs) { await pay(ref); await flw(ref, { amount: 50 }); }        // asked for N5,000, Flutterwave says only N50 was paid
  const before = wallet('payer@stress.ng');
  const r = await all(N, i => verify(refs[i])); await all(N, i => hook(refs[i]));
  check(`F11 under-payment: only the N50 really paid is credited, never the N5,000 asked ${N}/${N}`,
    r.every(x => x.body.status === 'SUCCESS') && wallet('payer@stress.ng') - before === N * 5000, String(wallet('payer@stress.ng') - before));
}
{ const refs = (await all(N, () => init(U.access_token, { purpose: 'TOPUP', amount_kobo: 500000 }))).map(x => x.body.reference);
  const patches = [{ currency: 'USD' }, { currency: 'GHS' }, { amount: 0 }, { amount: -5000 }, { currency: '' }];
  for (let i = 0; i < refs.length; i++) { await pay(refs[i]); await flw(refs[i], patches[i % patches.length]); }
  const before = wallet('payer@stress.ng');
  const r = await all(N, i => verify(refs[i])); await all(N, i => hook(refs[i]));
  check(`F12 wrong currency or zero/negative amounts credit nothing ${N}/${N}`,
    r.every(x => x.body.status === 'FAILED') && wallet('payer@stress.ng') === before, r.map(x => x.body.status).slice(0, 5).join(','));
}
{ let okc = 0, detail = '';                                                          // 50 different users, each with an empty wallet,
  for (let i = 0; i < N; i++) {                                                       // each "pays" N100 for a N2,963 seat
    const W = await signup(`broke${i}@stress.ng`, 'Empty Wallet ' + i);
    const ref = (await init(W.access_token, { purpose: 'SEAT', listing_id: L, contact: '' })).body.reference;
    await pay(ref); await flw(ref, { amount: 100 });
    await verify(ref); await hook(ref); await verify(ref);
    const seats = +sql(`select count(*) from memberships m join profiles p on p.id = m.buyer_id where p.email = 'broke${i}@stress.ng'`);
    if (seats === 0 && wallet(`broke${i}@stress.ng`) === 10000) okc++; else detail = `user ${i}: seats=${seats} wallet=${wallet(`broke${i}@stress.ng`)}`;
  }
  check(`F12b under-paid seat: no seat is given and only the N100 really paid reaches the wallet ${okc}/${N}`, okc === N, detail);
}

// ---------- F13-F14 real payments: credited exactly once ----------
{ const amounts = Array.from({ length: N }, (_, i) => (100 + i * 37) * 100);       // N100 ... N1,913
  const refs = (await all(N, i => init(U.access_token, { purpose: 'TOPUP', amount_kobo: amounts[i] }))).map(x => x.body.reference);
  const before = wallet('payer@stress.ng'), tBefore = topups('payer@stress.ng');
  for (const ref of refs) await pay(ref);
  for (let k = 0; k < 3; k++) { await all(N, i => verify(refs[i])); await all(N, i => hook(refs[i])); }   // 3 verifies + 3 webhooks each
  const sum = amounts.reduce((a, b) => a + b, 0);
  check(`F13 ${N} real payments, each replayed 6 times: credited exactly once, for the real amount`,
    wallet('payer@stress.ng') - before === sum && topups('payer@stress.ng') - tBefore === N, `${wallet('payer@stress.ng') - before} vs ${sum}`);
  const vBefore = wallet('attacker@stress.ng'), uBefore = wallet('payer@stress.ng');
  const r = await all(N, i => call('/functions/v1/payments-verify', { token: V.access_token, body: { reference: refs[i] } }));
  check(`F14 another user re-checking someone else's payment gains nothing ${N}/${N}`,
    wallet('attacker@stress.ng') === vBefore && wallet('payer@stress.ng') === uBefore && r.every(x => x.status === 200));
}

// ---------- F15 the crediting function itself is closed to the public ----------
{ const r = await all(N, i => call('/rest/v1/rpc/payment_complete', { token: i % 2 ? V.access_token : undefined,
    body: { p_reference: unpaid[i], p_paid_kobo: 99999900, p_currency: 'NGN', p_provider_id: 'x', p_channel: 'card' } }));
  check(`F15 calling payment_complete directly (signed in or not) refused ${N}/${N}`, r.every(x => x.status === 401 || x.status === 403) && wallet('attacker@stress.ng') === 0,
    r.map(x => x.status).slice(0, 6).join(','));
}

// ---------- the books ----------
check('Every wallet matches its ledger', sql(`select count(*) from wallet_accounts a left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x
  on x.account_id = a.id where a.balance_kobo <> coalesce(x.s, 0)`) === '0');
check('The attacker never got a single kobo', wallet('attacker@stress.ng') === 0);

for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '  -> ' + r.detail}`);
console.log(`\n${results.filter(r => r.ok).length} passed, ${results.filter(r => !r.ok).length} failed`);
