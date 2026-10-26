// End-to-end test: customer app + admin app + real SQL + real Edge Function code + fake Flutterwave.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)(process.env.NODE_PATH + '/playwright');
import { execFileSync } from 'node:child_process';
const B = 'http://localhost:8787', SHOTS = process.env.SHOTS || '.', results = [], errors = [];
const sql = s => { try { return execFileSync('psql', ['-h', process.env.PGHOST, '-p', process.env.PGPORT, '-U', 'postgres', '-d', 'e2e', '-X', '-q', '-t', '-A', '-c', s], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim(); } catch (e) { throw new Error('SQL failed: ' + String(e.stderr).trim().split('\n')[0]); } };
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail }); };
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
const phone = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 };
async function newPage(opts = phone) {
  const ctx = await browser.newContext(opts), p = await ctx.newPage();
  p.on('dialog', d => d.accept());
  p.on('pageerror', e => errors.push('pageerror: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' && !/fonts\.g|ERR_TUNNEL|Failed to load resource: the server responded with a status of (400|403|404)/.test(m.text())) errors.push(m.text()); });
  return p;
}
const toast = async p => { await p.waitForSelector('#toast:not([hidden])', { timeout: 8000 }); const t = (await p.textContent('#toast')).trim(); await p.evaluate(() => { document.getElementById('toast').hidden = true; }); return t; };
const PAGES = {};
async function step(name, fn) {
  try { await fn(); } catch (e) {
    let extra = '';
    for (const [k, p] of Object.entries(PAGES)) {
      try { await p.screenshot({ path: `${SHOTS}/fail-${name.replace(/\W+/g, '_')}-${k}.png` });
            extra += ` [${k}: ${p.url().replace(B, '')} sheet="${((await p.$('#sheet:not([hidden])')) ? await p.innerText('#sheet-box') : '').slice(0, 90).replace(/\n/g, ' ')}"]`; } catch (_) {}
    }
    check(name, false, e.message.split('\n')[0] + extra);
  }
}
async function signUp(p, name, email) {
  await p.goto(B); await p.waitForSelector('.hero');
  await p.click('.top [data-act=auth]'); await p.click('[data-act=authmode][data-v=up]');
  await p.fill('#a-name', name); await p.fill('#a-phone', '08031234567'); await p.fill('#a-email', email); await p.fill('#a-pass', 'password123');
  await p.click('#f-signup [type=submit]'); return toast(p);
}
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
const wallet = email => +sql(`select balance_kobo from wallet_accounts a join profiles p on p.id = a.owner_id where p.email = '${email}' and kind = 'WALLET'`);
const earnings = email => +sql(`select balance_kobo from wallet_accounts a join profiles p on p.id = a.owner_id where p.email = '${email}' and kind = 'EARNINGS'`);

// ---------- HOST signs up and lists Netflix ----------
const host = await newPage(); PAGES.host = host;
await step('host signup', async () => check('Host can create an account', /Account created/.test(await signUp(host, 'Hannah Host', 'host@subsplit.ng'))));
check('Customer app has NO admin tab or admin code', !(await host.$('.nav [data-v=admin]')) && !(await host.innerText('#app')).includes('Admin') && !(await (await fetch(B + '/')).text()).includes('admin_'));
check('Customer nav is Explore | My Subs | Wallet | Account', (await host.$$eval('.nav button span', s => s.map(x => x.textContent).join('|'))) === 'Explore|My Subs|Wallet|Account');
await step('host create listing', async () => {
  await host.click('.hero [data-act=create]');
  await host.click('.svc-grid button:has-text("Netflix")');
  const calc = await host.textContent('#sheet-box');
  check('Host sees platform price ₦8,500 + 4-seat limit (read-only)', calc.includes('₦8,500') && calc.includes('4 seats · set by SplitSub') && !(await host.$('#sheet-box input[id*=price]')));
  check('Default 30% markup: ₦11,050 total, ₦2,763/seat, host earns ₦2,486.70', calc.includes('₦11,050') && calc.includes('₦2,763') && calc.includes('₦2,486.70'), '');
  check('Markup choices stop at 30%', (await host.$$eval('[data-act=hmark]', b => b.map(x => x.dataset.v).join(','))) === '10,15,20,25,30');
  await host.click('[data-act=hmark][data-v="20"]');
  const c2 = await host.textContent('#sheet-box');
  check('20% markup: ₦2,550/seat, fee ₦255, host earns ₦2,295', c2.includes('₦2,550') && c2.includes('−₦255') && c2.includes('₦2,295'));
  await host.fill('#h-access', 'Email: netflix@hannah.ng\nPassword: S3cret!\nUse the profile with your name.');
  await host.setInputFiles('#h-proof', { name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
  await host.check('#h-own');
  await host.click('#f-create [type=submit]');
  check('Escrow agreement is required before submitting', /30-day escrow/.test(await toast(host)));
  await host.check('#h-agree');
  await host.screenshot({ path: SHOTS + '/1-host-share.png', fullPage: false });
  await host.click('#f-create [type=submit]');
  check('Listing submitted for review', /review/i.test(await toast(host)));
  check('Pending listing not visible on Explore', sql(`select count(*) from listings where status='PENDING_REVIEW'`) === '1' && sql(`select jsonb_array_length(explore_listings())`) === '0');
});
await step('host blocked from admin', async () => {
  await host.goto(B + '/admin/'); await host.waitForSelector('text=Access denied');
  check('Normal user opening /admin sees "Access denied" (no data)', (await host.innerText('#app')).includes('Access denied') && !(await host.innerText('#app')).includes('Dashboard'));
});

// ---------- ADMIN ----------
const admin = await newPage({ viewport: { width: 1280, height: 860 } }); PAGES.admin = admin;
await step('admin', async () => {
  await signUp(admin, 'Ade Owner', 'owner@subsplit.ng');
  await admin.goto(B + '/admin/'); await admin.waitForSelector('text=Access denied');
  check('New account is not admin until made admin in SQL', true);
  sql(`insert into admin_users (user_id) select id from auth.users where email = 'owner@subsplit.ng'`);   // 005_make_admin.sql
  await admin.reload(); await admin.waitForSelector('h1:has-text("Dashboard")');
  await admin.screenshot({ path: SHOTS + '/4-admin-dashboard.png' });
  await admin.click('.side [data-v=listings]'); await admin.waitForSelector('h1:has-text("Listings")');
  await admin.click('[data-act=listing]'); await admin.waitForSelector('[data-act=proof]');
  check('Admin sees private access details', (await admin.textContent('#sheet-box')).includes('S3cret!'));
  check('Listing shows the saved escrow agreement', (await admin.textContent('#sheet-box')).includes('accepted the 30-day escrow agreement'));
  await admin.click('#sheet-box [data-act=close]');
  await admin.click('.side [data-v=proofs]'); await admin.waitForSelector('h1:has-text("Proof of purchase")');
  await admin.click('[data-act=proofsheet]'); await admin.waitForSelector('#proof-view img, #proof-view iframe');
  check('Admin sees the private proof file inline', (await admin.getAttribute('#proof-view img, #proof-view iframe', 'src')).includes('/sign-local/host-proofs/'));
  await admin.fill('#pf-note', 'Blurry, please re-upload.');
  await admin.click('[data-act=pdecide][data-v=REJECT]'); await admin.click('[data-act=pdecide][data-v=REJECT]'); await toast(admin);
  check('Rejected proof sends the listing back to the host', sql(`select status || '/' || proof_status from listings`) === 'REJECTED/REJECTED');
  const failLive = (() => { try { sql(`update listings set status = 'LIVE'`); return false; } catch (e) { return /proof of purchase/.test(e.message); } })();
  check('Backend blocks going live without approved proof', failLive);
  await host.goto(B); await host.click('.nav [data-v=mysubs]'); await host.click('[data-act=subs][data-v=hosting]');
  check('Host sees the rejection reason', (await host.textContent('main')).includes('Blurry'));
  await host.click('[data-act=manage]'); await host.waitForSelector('#f-submit');
  await host.setInputFiles('#s-proof', { name: 'receipt2.png', mimeType: 'image/png', buffer: PNG });
  await host.click('#f-submit [type=submit]');
  check('Resubmitting needs the escrow agreement again', /30-day escrow/.test(await toast(host)));
  await host.check('#s-agree'); await host.click('#f-submit [type=submit]'); await toast(host);
  await admin.click('.side [data-v=proofs]'); await admin.waitForSelector('[data-act=proofsheet]'); await admin.click('[data-act=proofsheet]');
  await admin.click('[data-act=pdecide][data-v=APPROVE]'); await admin.click('[data-act=pdecide][data-v=APPROVE]');
  check('Admin approves proof: listing goes live', /approved/i.test(await toast(admin)) && sql(`select status from listings`) === 'LIVE');
});

// ---------- BUYER ----------
const buyer = await newPage(); PAGES.buyer = buyer;
await step('buyer explore', async () => {
  await signUp(buyer, 'Bola Buyer', 'buyer@subsplit.ng');
  await buyer.waitForSelector('#feed .card');
  const cardText = await buyer.textContent('#feed .card');
  check('Card: price ₦2,550/month, was ₦8,500, Save ₦5,950', cardText.includes('₦2,550/month') && cardText.includes('₦8,500') && cardText.includes('Save ₦5,950'), cardText);
  check('Card: "4 of 4 seats available", host, access, lengths', cardText.includes('4 of 4 seats available') && cardText.includes('@host') && cardText.includes('Shared login') && cardText.includes('1, 3, 6 or 12 months'));
  check('Explore never contains the password', !(await buyer.content()).includes('S3cret'));
  await buyer.screenshot({ path: SHOTS + '/2-explore.png' });
});
let seatRef = '';
await step('buyer pays for seat with Flutterwave', async () => {
  await buyer.click('#feed .card [data-act=join]'); await buyer.waitForSelector('text=Confirm your seat');
  const t = await buyer.textContent('#sheet-box');
  check('Confirm screen shows service, price, ₦200 fee, total ₦2,750', ['Netflix', 'Premium', '₦2,550/month', '1 month · 30 days', 'Shared login', '@host', 'available seats', 'Transaction fee', '₦200', 'Total to pay', '₦2,750'].every(x => t.includes(x)), t.slice(0, 300));
  check('Confirm screen offers 1, 3, 6 and 12 months with a start date', (await buyer.$$eval('[data-act=jlen]', b => b.map(x => x.dataset.v).join(','))) === '1,3,6,12' && !!(await buyer.$('#j-start')) && t.includes('Ends on'));
  await buyer.screenshot({ path: SHOTS + '/3-confirm.png' });
  await buyer.click('[data-act=payCard]'); await buyer.waitForURL(/flw\/checkout/);
  seatRef = buyer.url().split('/').pop();
  check('Seat payment amount set by backend (₦2,550 + ₦200 fee)', (await buyer.textContent('body')).includes('NGN 2,750'));
  await buyer.click('#pay'); await buyer.waitForSelector("text=You're in!");
  check('After Flutterwave: seat reserved, money verified on server', sql(`select status || '/' || paid_kobo || '/' || (membership_id is not null) from payments where reference = '${seatRef}'`) === 'SUCCESS/275000/true');
  check('Wallet nets to ₦0 (credited then charged)', wallet('buyer@subsplit.ng') === 0);
  await buyer.click('#sheet-box [data-act=close]');
  await buyer.waitForSelector('.card:has-text("Netflix")');
  await buyer.click('[data-act=access]'); await buyer.waitForSelector('#secret');
  check('Paid member sees login details', (await buyer.textContent('#secret')).includes('S3cret!'));
  await buyer.click('#sheet-box [data-act=close]');
  await buyer.screenshot({ path: SHOTS + '/5-mysubs.png' });
});
await step('duplicate + fake payments', async () => {
  const r1 = await (await fetch(`${B}/test/webhook/${seatRef}`)).text(), r2 = await (await fetch(`${B}/test/webhook/${seatRef}`)).text();
  check('Duplicate Flutterwave webhooks accepted but credit nothing extra', r1.includes('true') && r2.includes('true') && wallet('buyer@subsplit.ng') === 0 && sql(`select count(*) from wallet_transactions where payment_reference = '${seatRef}' and type = 'TOP_UP'`) === '1');
  const bad = await fetch(`${B}/test/webhook/${seatRef}?bad=1`);
  check('Webhook with a wrong signature is rejected (401)', bad.status === 401);
  // start a top-up but never pay, then pretend success from the browser
  const tok = await buyer.evaluate(() => JSON.parse(localStorage.getItem('subsplit-session')).access_token);
  const init = await (await fetch(`${B}/functions/v1/payments-init`, { method: 'POST', headers: { apikey: 'publishable-local', Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' }, body: JSON.stringify({ purpose: 'TOPUP', amount_kobo: 10000000 }) })).json();
  const ver = await (await fetch(`${B}/functions/v1/payments-verify`, { method: 'POST', headers: { apikey: 'publishable-local', 'Content-Type': 'application/json' }, body: JSON.stringify({ reference: init.reference }) })).json();
  check('Unpaid payment is NOT credited (fake success blocked)', ver.status === 'PENDING' && wallet('buyer@subsplit.ng') === 0, JSON.stringify(ver));
  const tooBig = await fetch(`${B}/functions/v1/payments-init`, { method: 'POST', headers: { apikey: 'publishable-local', Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' }, body: JSON.stringify({ purpose: 'TOPUP', amount_kobo: 999999999999 }) });
  check('Top-up above the platform limit is refused', tooBig.status === 400);
  const fakeSeat = await (await fetch(`${B}/functions/v1/payments-init`, { method: 'POST', headers: { apikey: 'publishable-local', Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' }, body: JSON.stringify({ purpose: 'SEAT', listing_id: sql(`select id from listings limit 1`), amount_kobo: 100 }) })).json();
  check('Buying the same seat twice is refused at payment start', /already have a seat/.test(fakeSeat.error || ''), JSON.stringify(fakeSeat));
  const noAuth = await fetch(`${B}/functions/v1/payments-init`, { method: 'POST', headers: { apikey: 'publishable-local', 'Content-Type': 'application/json' }, body: '{"purpose":"TOPUP","amount_kobo":500000}' });
  check('Payment start needs a signed-in user', noAuth.status === 401);
});
await step('top-up + cancel', async () => {
  await buyer.click('.nav [data-v=wallet]'); await buyer.click('.money [data-act=fund]');
  await buyer.fill('#f-amt', '5000'); await buyer.click('#f-fund [type=submit]'); await buyer.waitForURL(/checkout/);
  await buyer.click('#pay'); await buyer.waitForSelector('text=Money added');
  check('Top-up ₦5,000 lands in wallet once verified', wallet('buyer@subsplit.ng') === 500000);
  await buyer.click('#sheet-box [data-act=close]');
  await buyer.click('.money [data-act=fund]'); await buyer.fill('#f-amt', '2000'); await buyer.click('#f-fund [type=submit]'); await buyer.waitForURL(/checkout/);
  await buyer.click('#cancel'); await buyer.waitForSelector('text=Payment cancelled');
  await buyer.click('#sheet-box [data-act=close]'); await buyer.click('.nav [data-v=wallet]');
  check('Cancelled payment adds nothing and is marked cancelled', wallet('buyer@subsplit.ng') === 500000 && sql(`select count(*) from payments where status='ABANDONED'`) === '1');
  await buyer.screenshot({ path: SHOTS + '/6-wallet.png' });
});

// ---------- order chat + receipt ----------
await step('order chat', async () => {
  await buyer.goto(B); await buyer.click('.nav [data-v=mysubs]');
  await buyer.click('.card:has-text("Netflix") [data-act=chat]'); await buyer.waitForSelector('#f-chat');
  check('Order chat opens with the system message', (await buyer.textContent('#chat-box')).includes('created for Netflix'));
  await buyer.fill('#ch-body', 'Hi host, thanks for the seat!'); await buyer.click('#f-chat [type=submit]');
  await buyer.waitForSelector('#chat-box :text("thanks for the seat")');
  check('Buyer message saved', sql(`select count(*) from order_messages where sender_role = 'BUYER'`) === '1');
  await buyer.click('#sheet-box [data-act=close]');
  await host.goto(B); await host.click('.nav [data-v=mysubs]'); await host.click('[data-act=subs][data-v=orders]');
  check('Host sees an unread badge on the order', (await host.textContent('main')).includes('1 new'));
  await host.click('.card.tap [data-act=chat], .card.tap'); await host.waitForSelector('#f-chat');
  check('Host sees the buyer message', (await host.textContent('#chat-box')).includes('thanks for the seat'));
  await host.fill('#ch-body', 'Welcome! Use the profile with your name.'); await host.click('#f-chat [type=submit]');
  await host.waitForSelector('#chat-box :text("Welcome!")'); await host.click('#sheet-box [data-act=close]');
  await admin.click('.side [data-v=chats]'); await admin.waitForSelector('h1:has-text("Order chats")');
  await admin.click('[data-act=achat]'); await admin.waitForSelector('#f-achat');
  const at = await admin.textContent('#achat-box');
  check('Admin can read buyer and host messages', at.includes('thanks for the seat') && at.includes('Welcome!'));
  await admin.fill('#ac-body', 'SplitSub support here, shout if you need us.'); await admin.click('#f-achat [type=submit]');
  await admin.waitForSelector('#achat-box :text("shout if you need us")');
  check('Admin message saved and audited', sql(`select count(*) from order_messages where sender_role = 'ADMIN'`) === '1' && sql(`select count(*) from admin_audit_logs where action = 'ORDER_CHAT_MESSAGE'`) === '1');
  await admin.click('#sheet-box [data-act=close]');
  // receipt + PDF
  await buyer.goto(B); await buyer.click('.nav [data-v=mysubs]');
  await buyer.click('.card:has-text("Netflix") [data-act=receipt]'); await buyer.waitForSelector('text=Purchase receipt');
  const rt = await buyer.textContent('#sheet-box');
  check('Receipt shows ID, price, ₦200 fee, total, method, status', ['Transaction ID', 'SUB-', '₦2,550', '₦200', '₦2,750', 'Flutterwave', 'Successful'].every(x => rt.includes(x)), rt.slice(0, 300));
  const [dl] = await Promise.all([buyer.waitForEvent('download'), buyer.click('[data-act=rcptpdf]')]);
  const path = await dl.path(); const head = (await import('node:fs')).readFileSync(path).slice(0, 8).toString();
  check('Receipt downloads as a real PDF', head.startsWith('%PDF-1.4') && dl.suggestedFilename().endsWith('.pdf'), head);
  await buyer.click('#sheet-box [data-act=close]');
});

// ---------- second listing (family invite) + wallet join + host marks sent ----------
await step('family invite flow', async () => {
  await host.goto(B); await host.waitForSelector('.hero');
  await host.click('.hero [data-act=create]'); await host.click('.svc-grid button:has-text("YouTube")');
  await host.click('[data-act=hmark][data-v="10"]'); await host.selectOption('#h-seats', '2');
  await host.setInputFiles('#h-proof', { name: 'yt.png', mimeType: 'image/png', buffer: PNG }); await host.check('#h-own');
  await host.check('#h-agree'); await host.click('#f-create [type=submit]'); await toast(host);
  await admin.click('.side [data-v=listings]'); await admin.waitForSelector('h1:has-text("Listings")'); await admin.click('[data-act=listing]');
  await admin.waitForSelector('[data-act=review][data-v=APPROVE]'); await admin.click('[data-act=review][data-v=APPROVE]'); await toast(admin);
  await buyer.goto(B); await buyer.waitForSelector('#feed .card:has-text("YouTube")');
  const yt = await buyer.textContent('#feed .card:has-text("YouTube")');
  check('YouTube 10% markup: ₦3,600×1.1÷5 = ₦792, "2 of 2 seats available"', yt.includes('₦792') && yt.includes('2 of 2 seats available'), yt);
  await buyer.click('#feed .card:has-text("YouTube") [data-act=join]'); await buyer.waitForSelector('#j-contact');
  await buyer.fill('#j-contact', 'bola.family@gmail.com'); await buyer.click('[data-act=payWallet]');
  await buyer.waitForSelector('text=Waiting for the host');
  check('Wallet join: ₦792 + ₦200 fee charged from wallet', wallet('buyer@subsplit.ng') === 500000 - 79200 - 20000);
  await buyer.click('#sheet-box [data-act=close]');
  await host.reload(); await host.click('.nav [data-v=mysubs]'); await host.click('[data-act=subs][data-v=hosting]');
  check('Host is told a member is waiting for access', (await host.textContent('main')).includes('waiting for access'));
  await host.click('.card:has-text("YouTube") [data-act=manage]'); await host.waitForSelector('text=bola.family@gmail.com');
  await host.click('[data-act=sent]'); await toast(host);
  await buyer.reload(); await buyer.click('.nav [data-v=mysubs]');
  check('Buyer sees "Host sent your access"', (await buyer.textContent('main')).includes('Host sent your access'));
  await buyer.click('.card:has-text("YouTube") [data-act=complete]'); 
  check('Buyer marks the order completed', /completed/i.test(await toast(buyer)) && sql(`select count(*) from memberships where completed_at is not null`) === '1');
  await buyer.reload(); await buyer.click('.nav [data-v=mysubs]');
  check('Completed order shows once and has no second button', (await buyer.textContent('.card:has-text("YouTube")')).includes('Completed') && !(await buyer.$('.card:has-text("YouTube") [data-act=complete]')));
});

// ---------- dispute -> partial refund ----------
await step('dispute', async () => {
  await buyer.click('.card:has-text("Netflix") [data-act=report]'); await buyer.fill('#r-text', 'The password was changed and I cannot log in.');
  await buyer.click('#f-report [type=submit]'); await toast(buyer);
  check('Report creates a dispute and freezes the seat money', sql(`select m.status from memberships m join listings l on l.id=m.listing_id join service_plans p on p.id=l.plan_id join services s on s.id=p.service_id where s.name='Netflix'`) === 'DISPUTED');
  await admin.click('.side [data-v=disputes]'); await admin.waitForSelector('text=password was changed');
  const did = await admin.getAttribute('[data-act=dispute][data-v=PARTIAL_REFUND]', 'data-id');
  await admin.fill('#dn-' + did, 'Access was down for 10 days.'); await admin.fill('#da-' + did, '1000');
  await admin.click('[data-act=dispute][data-v=PARTIAL_REFUND]'); await admin.click('[data-act=dispute][data-v=PARTIAL_REFUND]'); await toast(admin);
  check('Partial refund ₦1,000 to buyer', wallet('buyer@subsplit.ng') === 500000 - 79200 - 20000 + 100000);
  check('Host gets 90% of remaining ₦1,550 = ₦1,395', earnings('host@subsplit.ng') === 139500, String(earnings('host@subsplit.ng')));
});

// ---------- admin changes platform price ----------
await step('admin pricing', async () => {
  await admin.click('.side [data-v=services]'); await admin.waitForSelector('h1:has-text("Services")');
  await admin.screenshot({ path: SHOTS + '/7-admin-services.png' });
  await admin.click('[data-act=plan]:has-text("Premium")'); await admin.waitForSelector('#pl-price');
  await admin.fill('#pl-price', '9000');
  await admin.fill('#pl-max', '40'); await admin.click('#f-plan [type=submit]');
  check('Admin cannot set markup above 30%', /30%/.test(await toast(admin)));
  await admin.fill('#pl-max', '30'); await admin.click('#f-plan [type=submit]'); await toast(admin);
  await buyer.goto(B); await buyer.waitForSelector('#feed .card:has-text("Netflix")');
  check('New platform price flows to Explore: ₦9,000×1.2÷4 = ₦2,700', (await buyer.textContent('#feed .card:has-text("Netflix")')).includes('₦2,700'));
  await admin.click('.side [data-v=audit]'); await admin.waitForSelector('h1:has-text("Audit")');
  check('Audit log shows old → new price', (await admin.textContent('main')).includes('normal_price_kobo: 850000 → 900000'));
});

// ---------- period ends -> earnings -> withdrawal ----------
await step('withdrawal', async () => {
  check('Escrow is not released early', sql(`select release_due_escrow()`) === '0');
  sql(`update memberships set ends_at = now() - interval '1 minute', release_at = now() - interval '1 minute' where status = 'ACTIVE'`);
  await host.goto(B); await host.waitForSelector('.hero'); await host.click('.nav [data-v=wallet]');
  const w = await host.textContent('main');
  check('Host earnings after period end: ₦1,395 + ₦712.80 = ₦2,107.80 available', w.includes('₦2,107.80'), w.slice(0, 400));
  await host.click('.money [data-act=withdraw]'); await host.fill('#w-amt', '500'); await host.fill('#w-acct', '0123456789');
  await host.click('#f-withdraw [type=submit]');
  check('Withdrawal below ₦1,000 minimum refused', /smallest withdrawal/i.test(await toast(host)));
  await host.fill('#w-amt', '2000');
  check('Withdraw screen shows ₦200 fee and ₦1,800 payout', (await host.textContent('#w-calc')).includes('₦1,800'));
  await host.click('#f-withdraw [type=submit]'); await host.waitForSelector('text=Withdrawal receipt');
  const wr = await host.textContent('#sheet-box');
  check('Withdrawal receipt text is right', wr.includes('Withdrawal fee') && wr.includes('₦200') && wr.includes('₦1,800') && wr.includes('Amount paid out'), wr.slice(0, 300));
  await host.click('#sheet-box [data-act=close]');
  await admin.click('.side [data-v=withdrawals]'); await admin.waitForSelector('text=0123456789');
  await admin.click('[data-act=wd][data-v=PAID]'); await admin.click('[data-act=wd][data-v=PAID]'); await toast(admin);
  check('Admin marks withdrawal paid; ledger entry exists', sql(`select status from withdrawals`) === 'PAID' && sql(`select count(*) from wallet_transactions where type='WITHDRAWAL'`) === '1');
  check('Withdrawal stored fee N200 and payout N1,800', sql(`select fee_kobo || '/' || payout_kobo from withdrawals`) === '20000/180000');
});

// ---------- support + notifications ----------
await step('support', async () => {
  await buyer.click('.nav [data-v=account]'); await buyer.click('[data-act=tickets]');
  await buyer.fill('#tk-subj', 'Invite question'); await buyer.fill('#tk-body', 'How long does a family invite take?'); await buyer.click('#f-ticket [type=submit]'); await toast(buyer);
  await admin.click('.side [data-v=support]'); await admin.click('[data-act=ticket]'); await admin.fill('#tr-body', 'Usually within 2 hours.'); await admin.click('#f-treply [type=submit]'); await toast(admin);
  await buyer.reload(); await buyer.waitForSelector('.top [data-act=notes]');
  await buyer.click('.top [data-act=notes]');
  const n = await buyer.textContent('#sheet-box');
  check('Notifications: payment, joined, access sent, dispute, refund, support reply', ['Payment successful', 'You joined Netflix', 'access was sent', 'We got your report', 'refunded', 'Support replied'].every(x => n.includes(x)), n.slice(0, 300));
  await buyer.click('#sheet-box [data-act=close]');
});

// ---------- suggest, whatsapp, credits, search, referral ----------
await step('suggest a subscription', async () => {
  await buyer.goto(B); await buyer.waitForSelector('#q'); await buyer.fill('#q', 'Disney');
  await buyer.waitForSelector('#f-suggest');
  check('Search with no results offers "Suggest a Subscription"', (await buyer.textContent('#feed')).includes('Suggest a Subscription'));
  await buyer.click('#f-suggest [type=submit]'); check('Request sent', /Request sent/.test(await toast(buyer)));
  await admin.click('.side [data-v=requests]'); await admin.waitForSelector('[data-act=reqsheet]');
  await admin.click('[data-act=reqsheet]'); await admin.click('[data-act=rqdo][data-v=ADDED]'); await admin.click('[data-act=rqdo][data-v=ADDED]'); await toast(admin);
  check('Admin marks it added; user is notified', sql(`select status from subscription_requests`) === 'ADDED' && sql(`select count(*) from notifications where type = 'REQUEST_ADDED'`) === '1');
});
await step('whatsapp link', async () => {
  await admin.click('.side [data-v=settings]'); await admin.waitForSelector('#st-walink');
  await admin.fill('#st-walink', 'http://bad.example/x'); await admin.click('#f-settings [type=submit]');
  check('Bad WhatsApp link refused', /WhatsApp link/.test(await toast(admin)));
  await admin.fill('#st-walink', 'https://wa.me/2348012345678'); await admin.click('#f-settings [type=submit]'); await toast(admin);
  await buyer.goto(B); await buyer.waitForSelector('.foot');
  check('Customer app shows the WhatsApp support link from settings', (await buyer.getAttribute('.foot a', 'href')) === 'https://wa.me/2348012345678');
});
await step('credits + search', async () => {
  const before = wallet('buyer@subsplit.ng');
  await admin.click('.side [data-v=credits]'); await admin.waitForSelector('#f-credit1');
  const uname = sql(`select username from profiles where email = 'buyer@subsplit.ng'`);
  await admin.fill('#c1-user', uname); await admin.fill('#c1-amt', '100'); await admin.fill('#c1-why', 'Welcome gift');
  await admin.click('#f-credit1 [type=submit]'); await admin.click('#f-credit1 [type=submit]'); await toast(admin);
  check('Admin credit adds ₦100 to the wallet with a ledger row', wallet('buyer@subsplit.ng') === before + 10000 && sql(`select count(*) from wallet_transactions where type = 'ADMIN_CREDIT'`) === '2');
  await admin.click('.side [data-v=search]'); await admin.waitForSelector('#sq');
  const ord = sql(`select txn_ref from memberships order by created_at limit 1`);
  await admin.fill('#sq', ord); await admin.click('#f-search button'); await admin.waitForSelector('text=Wallet movements');
  const tv = await admin.textContent('main');
  check('Transaction search shows order, fees, wallet movements and audit', ['Buyer fee', '₦200', 'purchase fee', 'host earning pending', 'Admin actions & audit'].every(x => tv.toLowerCase().includes(x.toLowerCase())), tv.slice(0, 200));
  await admin.click('.side [data-v=desk]'); await admin.waitForSelector('h1:has-text("Approval Desk")');
  check('Approval desk loads', (await admin.textContent('main')).includes('Orders needing attention'));
});
await step('referral', async () => {
  const code = sql(`select referral_code from profiles where email = 'host@subsplit.ng'`);
  const r = await newPage(); await r.goto(B + '/?ref=' + code); await r.waitForSelector('#a-ref');
  check('Invite link opens sign-up with the code filled in', (await r.inputValue('#a-ref')) === code);
  await r.fill('#a-name', 'Ref Friend'); await r.fill('#a-phone', '08030000000'); await r.fill('#a-email', 'friend@subsplit.ng'); await r.fill('#a-pass', 'password123');
  await r.click('#f-signup [type=submit]'); await toast(r);
  check('Referral is recorded at sign-up', sql(`select count(*) from referrals r join profiles p on p.id = r.referred_id where p.email = 'friend@subsplit.ng'`) === '1');
});

// ---------- 6-digit email code: sign-up, wrong code, resend, unconfirmed sign-in, forgot password ----------
await step('email codes', async () => {
  const hasSession = p => p.evaluate(() => !!localStorage.getItem('subsplit-session'));
  const fillUp = async (p, em) => {
    await p.goto(B); await p.waitForSelector('.hero');
    await p.click('.top [data-act=auth]'); await p.click('[data-act=authmode][data-v=up]');
    await p.fill('#a-name', 'Code Tester'); await p.fill('#a-phone', '08031112222'); await p.fill('#a-email', em); await p.fill('#a-pass', 'password123');
    await p.click('#f-signup [type=submit]');
  };
  const c = await newPage(); PAGES.code = c;
  await fillUp(c, 'coder@code.test'); await c.waitForSelector('#f-code');
  const sheet = await c.innerText('#sheet-box');
  check('Sign-up asks for a code (no link), shows the email and 15-minute life', sheet.includes('coder@code.test') && sheet.includes('15 minutes') && sheet.includes('6-digit'), sheet.slice(0, 120));
  check('Not signed in until the code is checked', !(await hasSession(c)));
  check('"Send a new code" waits 60 seconds first', await c.$eval('#c-resend', b => b.disabled && /in \d+s/.test(b.textContent)));
  await c.fill('#c-code', 'abc'); await c.click('#f-code [type=submit]');
  check('Letters are rejected before asking the server', /6-digit/.test(await toast(c)));
  await c.fill('#c-code', '000000'); await c.click('#f-code [type=submit]');
  const bad = await toast(c);
  check('Wrong code gives a clear message and stays on the code screen', /wrong or has expired/.test(bad) && !!(await c.$('#f-code')) && !(await hasSession(c)), bad);
  await c.fill('#c-code', '123 456'); await c.click('#f-code [type=submit]');
  check('Right code (spaces ignored) confirms and signs in', /Email confirmed/.test(await toast(c)) && await hasSession(c));
  check('Profile and wallet were created for the new account', sql(`select count(*) from profiles where email = 'coder@code.test'`) === '1');

  const u = await newPage(); PAGES.unconf = u;
  await fillUp(u, 'late@code.test'); await u.waitForSelector('#f-code');
  await u.evaluate(() => document.querySelector('[data-act=close]') && 0); await u.goto(B); await u.waitForSelector('.hero');
  await u.click('.top [data-act=auth]'); await u.fill('#a-email', 'late@code.test'); await u.fill('#a-pass', 'password123'); await u.click('#f-signin [type=submit]');
  await u.waitForSelector('#f-code');
  check('Signing in before confirming opens the code screen', (await u.innerText('#sheet-box')).includes('late@code.test') && !(await hasSession(u)));

  const f = await newPage(); PAGES.forgot = f;
  await f.goto(B); await f.waitForSelector('.hero'); await f.click('.top [data-act=auth]');
  await f.click('[data-act=forgot]'); check('Forgot password with no email asks for the email', /Type your email/.test(await toast(f)));
  await f.fill('#a-email', 'coder@code.test'); await f.click('[data-act=forgot]'); await f.waitForSelector('#f-code');
  check('Forgot password sends a code (not a link)', (await f.innerText('#sheet-box')).includes('Reset your password'));
  await f.fill('#c-code', '123456'); await f.click('#f-code [type=submit]'); await f.waitForSelector('#f-pass');
  check('Right code lets the person choose a new password', (await f.innerText('#sheet-box')).includes('Choose a new password'));
  await f.fill('#np', 'brandnew9876'); await f.click('#f-pass [type=submit]'); check('New password saved', /Password changed/.test(await toast(f)));
  const g = await newPage(); PAGES.relogin = g;
  await g.goto(B); await g.waitForSelector('.hero'); await g.click('.top [data-act=auth]');
  await g.fill('#a-email', 'coder@code.test'); await g.fill('#a-pass', 'brandnew9876'); await g.click('#f-signin [type=submit]');
  check('Signing in with the new password works', /Welcome back/.test(await toast(g)) && await hasSession(g));
});

// ---------- admin dashboard health + phone layouts ----------
await step('health', async () => {
  await admin.click('.side [data-v=dashboard]'); await admin.waitForSelector('h1:has-text("Dashboard")');
  check('Ledger balanced after everything', (await admin.textContent('main')).includes('Ledger balanced'));
  check('Dashboard shows platform earnings (fees + commissions − credit) = ₦734.20', (await admin.textContent('main')).includes('₦734.20'));
  const adminPhone = await newPage();
  await adminPhone.goto(B); await adminPhone.evaluate(s => localStorage.setItem('subsplit-session', s), await admin.evaluate(() => localStorage.getItem('subsplit-session')));
  await adminPhone.goto(B + '/admin/'); await adminPhone.waitForSelector('h1:has-text("Dashboard")');
  check('Admin works on a phone without sideways scrolling', await adminPhone.evaluate(() => document.documentElement.scrollWidth <= 390));
  await adminPhone.screenshot({ path: SHOTS + '/8-admin-phone.png' });
  for (const t of ['explore', 'mysubs', 'wallet', 'account']) { await buyer.click('.nav [data-v=' + t + ']'); }
  check('Customer app: no sideways scrolling at 390px', await buyer.evaluate(() => document.documentElement.scrollWidth <= 390));
});

// ---------- editable withdrawal fee list + admin delete account ----------
await step('fee list', async () => {
  await admin.click('.side [data-v=settings]'); await admin.waitForSelector('#f-fees');
  check('Admin shows the fee list with 5 rows (last is "and above")', (await admin.$$('#fee-rows .feerow')).length === 5 && (await admin.inputValue('#fee-rows .feerow:last-child .fr-up')) === 'and above');
  await admin.fill('#fee-try', '10000');
  check('Admin "try an amount": ₦10,000 -> ₦800 fee, ₦9,200 received', (await admin.textContent('#fee-try-out')).includes('₦800') && (await admin.textContent('#fee-try-out')).includes('₦9,200'));
  await admin.fill('#fee-rows .feerow:first-child .fr-val', '150');
  await admin.click('[data-act=fee-add]');
  check('Add a row works (6 rows)', (await admin.$$('#fee-rows .feerow')).length === 6);
  await admin.click('#fee-rows .feerow:nth-child(5) [data-act=fee-del]');
  check('Remove a row works (5 rows)', (await admin.$$('#fee-rows .feerow')).length === 5);
  await admin.click('#f-fees [type=submit]'); check('Saving the fee list says so', /Fee list saved/.test(await toast(admin)));
  check('Database now has ₦150 for the first row', sql(`select (withdrawal_fee_tiers -> 0 ->> 'flat_kobo') from platform_settings`) === '15000');
  await admin.fill('#fee-rows .feerow:first-child .fr-val', '0'); await admin.fill('#fee-rows .feerow:nth-child(2) .fr-up', '1');
  await admin.click('#f-fees [type=submit]'); check('A bad list is refused with a clear message', /higher than the row above|lower than/.test(await toast(admin)));
  const cust = await newPage(); PAGES.cust = cust;
  await cust.goto(B); await cust.waitForSelector('.hero'); await cust.evaluate(s => localStorage.setItem('subsplit-session', s), await buyer.evaluate(() => localStorage.getItem('subsplit-session')));
  await cust.goto(B); await cust.waitForSelector('.hero'); await cust.click('.nav [data-v=wallet]');
  await cust.click('[data-act=feecalc]'); await cust.waitForSelector('#fc-wd');
  const txt = await cust.textContent('#sheet-box');
  check('Wallet fee page lists the withdrawal fee rows (₦150 flat ... 10.19%)', txt.includes('₦150 flat') && txt.includes('10.19%') && txt.includes('8%') && !txt.includes('Fees are flat'), txt.slice(-400));
  await cust.fill('#fc-wd', '2000');
  check('Fee calculator uses the edited list: ₦2,000 -> fee ₦150, receive ₦1,850', (await cust.textContent('#fc-wd-out')).includes('₦150') && (await cust.textContent('#fc-wd-out')).includes('₦1,850'));
  await cust.fill('#fc-wd', '10000');
  check('Fee calculator: ₦10,000 -> 8% = ₦800, receive ₦9,200', (await cust.textContent('#fc-wd-out')).includes('₦800') && (await cust.textContent('#fc-wd-out')).includes('₦9,200'));
  sql(`update platform_settings set withdrawal_fee_tiers = '[{"upto_kobo":299999,"flat_kobo":20000},{"upto_kobo":5000000,"bps":800},{"upto_kobo":20000000,"bps":900},{"upto_kobo":30000000,"bps":1000},{"upto_kobo":null,"bps":1019}]'::jsonb`);
  await cust.close();
});
await step('admin delete account', async () => {
  const c = await newPage(); PAGES.clean = c;
  await signUp(c, 'Clean Slate', 'clean@subsplit.ng');
  const cu = sql(`select username from profiles where email = 'clean@subsplit.ng'`), cid = sql(`select id from profiles where email = 'clean@subsplit.ng'`);
  await admin.click('.side [data-v=users]'); await admin.fill('#u-q', 'clean@subsplit.ng'); await admin.press('#u-q', 'Enter');
  await admin.waitForSelector('[data-act=user]'); await admin.click('[data-act=user]'); await admin.waitForSelector('#f-udel');
  check('Delete form explains what is erased and kept', (await admin.textContent('#f-udel')).includes('history stays in the ledger'));
  await admin.fill('#ud-name', 'wrong'); await admin.click('#f-udel [type=submit]'); await admin.click('#f-udel [type=submit]');
  check('Wrong username is refused', /Type the username/.test(await toast(admin)));
  await admin.fill('#ud-name', cu); await admin.fill('#ud-why', 'test cleanup'); await admin.click('#f-udel [type=submit]'); await admin.click('#f-udel [type=submit]');
  check('Clean account is deleted completely', /Account removed/.test(await toast(admin)) && sql(`select count(*) from profiles where id = '${cid}'`) === '0' && sql(`select count(*) from auth.users where id = '${cid}'`) === '0');
  check('Deletion is in the audit log', sql(`select count(*) from admin_audit_logs where action = 'CLOSE_ACCOUNT' and note = 'test cleanup'`) === '1');

  const d = await newPage(); PAGES.hist = d;
  await signUp(d, 'Close Me', 'closeme@subsplit.ng');
  const du = sql(`select username from profiles where email = 'closeme@subsplit.ng'`), did = sql(`select id from profiles where email = 'closeme@subsplit.ng'`);
  await admin.click('.side [data-v=users]'); await admin.fill('#u-q', 'closeme@subsplit.ng'); await admin.press('#u-q', 'Enter');
  await admin.waitForSelector('[data-act=user]'); await admin.click('[data-act=user]'); await admin.waitForSelector('#f-adjust');
  await admin.fill('#aj-amt', '500'); await admin.fill('#aj-note', 'test'); await admin.click('#f-adjust [type=submit]'); await admin.click('#f-adjust [type=submit]'); await toast(admin);
  await admin.click('.side [data-v=users]'); await admin.fill('#u-q', 'closeme@subsplit.ng'); await admin.press('#u-q', 'Enter');
  await admin.waitForSelector('[data-act=user]'); await admin.click('[data-act=user]'); await admin.waitForSelector('#f-udel');
  await admin.fill('#ud-name', du); await admin.click('#f-udel [type=submit]'); await admin.click('#f-udel [type=submit]');
  check('Account with money is blocked until the balance is ₦0', /Balance must be/.test(await toast(admin)) && sql(`select count(*) from profiles where id = '${did}'`) === '1');
  await admin.click('#sheet-box [data-act=close]');
  await admin.click('.side [data-v=users]'); await admin.fill('#u-q', 'closeme@subsplit.ng'); await admin.press('#u-q', 'Enter');
  await admin.waitForSelector('[data-act=user]'); await admin.click('[data-act=user]'); await admin.waitForSelector('#f-adjust');
  await admin.fill('#aj-amt', '-500'); await admin.fill('#aj-note', 'clear'); await admin.click('#f-adjust [type=submit]'); await admin.click('#f-adjust [type=submit]'); await toast(admin);
  await admin.click('.side [data-v=users]'); await admin.fill('#u-q', 'closeme@subsplit.ng'); await admin.press('#u-q', 'Enter');
  await admin.waitForSelector('[data-act=user]'); await admin.click('[data-act=user]'); await admin.waitForSelector('#f-udel');
  await admin.fill('#ud-name', du); await admin.click('#f-udel [type=submit]'); await admin.click('#f-udel [type=submit]');
  check('Account with history is closed: ' + 'details erased', /Account removed/.test(await toast(admin)) && sql(`select username like 'removed-%' and full_name = 'Removed user' and phone = '' and email like 'removed-%' and closed_at is not null from profiles where id = '${did}'`) === 't');
  check('Closed account keeps its ledger rows and ledger still balances', +sql(`select count(*) from wallet_transactions where user_id = '${did}'`) >= 2 && sql(`set "request.jwt.claim.sub" = '${sql("select id from profiles where email = 'owner@subsplit.ng'")}'; set role authenticated; select jsonb_array_length(admin_ledger_check())`) === '0');
  check('Closed account login is blocked and email freed', sql(`select banned from auth.users where id = '${did}'`) === 't' && sql(`select email like 'removed-%' from auth.users where id = '${did}'`) === 't');
  const e2 = await newPage(); PAGES.again = e2;
  await e2.goto(B); await e2.waitForSelector('.hero'); await e2.click('.top [data-act=auth]');
  await e2.fill('#a-email', 'closeme@subsplit.ng'); await e2.fill('#a-pass', 'password123'); await e2.click('#f-signin [type=submit]');
  check('Closed account cannot sign in', /Invalid|incorrect|wrong/i.test(await toast(e2)));
  const own = sql(`select id from profiles where email = 'owner@subsplit.ng'`);
  const r = await admin.evaluate(async (id) => { try { await API.fn('admin-delete-user', {user_id:id, confirm:'x'}); return 'ok'; } catch (e) { return e.message; } }, own);
  check('Admin cannot delete their own account', /own account|Type the username|admin/i.test(r), r);
});

// ---------- admin adds their own listing with proof: live at once (016) ----------
await step('admin add listing', async () => {
  const own = sql(`select username from profiles where email = 'owner@subsplit.ng'`);
  await admin.click('.side [data-v=listings]'); await admin.waitForSelector('h1:has-text("Listings")');
  await admin.click('[data-act=addlisting]'); await admin.waitForSelector('#f-alist');
  check('Add listing form says it goes live under the admin account', (await admin.textContent('#sheet-box')).includes('@' + own));
  const nf = await admin.evaluate(() => [...document.querySelectorAll('#al-plan option')].find(o => o.textContent.startsWith('Netflix')).value);
  await admin.selectOption('#al-plan', nf); await admin.selectOption('#al-markup', '20'); await admin.selectOption('#al-seats', '2');
  const pv = await admin.textContent('#al-preview');
  check('Preview: ₦9,000 +20% ÷ 4 = ₦2,700 seat, ₦2,430 earned per seat, ₦4,860 for 2', pv.includes('₦2,700') && pv.includes('₦2,430') && pv.includes('₦4,860'), pv);
  await admin.click('#f-alist [type=submit]');
  check('Login plan asks for the login details first', /login details/.test(await toast(admin)));
  await admin.fill('#al-access', 'Email: owner-netflix@splitsub.ng  Password: Adm1nOnly!');
  await admin.click('#f-alist [type=submit]');
  check('Proof of the plan is required', /proof/i.test(await toast(admin)));
  await admin.setInputFiles('#al-proof', { name: 'owner-receipt.png', mimeType: 'image/png', buffer: PNG });
  await admin.fill('#al-proofnote', 'Renews on the 5th');
  await admin.click('#f-alist [type=submit]');
  check('Publishing says it is live', /live now/.test(await toast(admin)));
  await admin.waitForSelector('[data-act=listing]');
  const row = sql(`select l.status || '|' || l.proof_status || '|' || l.seats_offered || '|' || l.markup_pct from listings l join profiles p on p.id = l.host_id where p.email = 'owner@subsplit.ng'`);
  check('Listing is LIVE with approved proof, 2 seats, 20% markup', row === 'LIVE|APPROVED|2|20', row);
  check('Proof file saved privately in the admin folder', sql(`select count(*) from storage.objects o join profiles p on o.name like p.id || '/%' where p.email = 'owner@subsplit.ng' and o.bucket_id = 'host-proofs'`) === '1');
  check('Admin Listings opens on Live and shows it', (await admin.textContent('main')).includes('@' + own) && (await admin.getAttribute('[data-act=filter][data-v=LIVE]', 'aria-pressed')) === 'true');
  await admin.click(`[data-act=listing]:has-text("@${own}")`); await admin.waitForSelector('[data-act=proof]');
  const det = await admin.textContent('#sheet-box');
  check('Detail shows approved proof, escrow agreement and private login', det.includes('Approved') && det.includes('accepted the 30-day escrow agreement') && det.includes('Adm1nOnly!'));
  await admin.click('#sheet-box [data-act=close]');
  await buyer.goto(B); await buyer.waitForSelector('#feed .card');
  check('Buyers see it on Explore straight away', (await buyer.textContent('#feed')).includes('@' + own));
  check('Explore never contains the admin listing password', !(await buyer.content()).includes('Adm1nOnly'));
  const r = await host.evaluate(async () => { try { await API.rpc('admin_add_listing', {p_listing:'11111111-1111-4111-8111-111111111111', p_plan:'11111111-1111-4111-8111-111111111111', p_markup_pct:20, p_seats:1, p_proof_path:'x'}); return 'ok'; } catch (e) { return e.message; } });
  check('A normal user cannot use the admin shortcut', /admins only/i.test(r), r);
});

// ====================== 017: card switch, lengths, renewals, moves, creators, bulk messages ======================
const lagosDay = n => new Date(Date.now() + 36e5 + n * 864e5).toISOString().slice(0, 10);
const fund = (email, kobo) => sql(`select _post(id, 'WALLET', 'TOP_UP', ${kobo}, 'e2e money', _ref('E2E')) from profiles where email = '${email}'`);
const twice = async (p, sel) => { await p.click(sel); await p.click(sel); };
const ownU = sql(`select username from profiles where email = 'owner@subsplit.ng'`);
const hostNf = () => sql(`select l.id from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id join profiles h on h.id = l.host_id where h.email = 'host@subsplit.ng' and s.name = 'Netflix' order by l.created_at limit 1`);
const NF = '.card:has(h3:text-is("Netflix"))';

await step('card payments switch', async () => {
  await admin.click('.side [data-v=dashboard]'); await admin.waitForSelector('h1:has-text("Dashboard")');
  check('Dashboard shows the Flutterwave switch (ON)', (await admin.textContent('main')).includes('Card payments (Flutterwave)') && !!(await admin.$('[data-act=cardpay][data-v="0"]')));
  await twice(admin, '[data-act=cardpay][data-v="0"]');
  check('Admin switches card payments OFF', /OFF/.test(await toast(admin)) && sql(`select card_payments_enabled from platform_settings`) === 'f');
  sql(`update platform_settings set manual_funding_enabled = false`);
  await buyer.goto(B); await buyer.waitForSelector('.hero');
  await buyer.click('.nav [data-v=wallet]'); await buyer.click('.money [data-act=fund]'); await buyer.waitForSelector('#sheet:not([hidden])');
  check('Card OFF + bank transfer OFF: the app says adding money is paused', (await buyer.textContent('#sheet-box')).includes('Adding money is paused'));
  sql(`update platform_settings set manual_funding_enabled = true`);
  await buyer.goto(B); await buyer.waitForSelector('.hero');
  await buyer.click('.nav [data-v=wallet]'); await buyer.click('.money [data-act=fund]'); await buyer.waitForSelector('#f-fund');
  const t = await buyer.textContent('#sheet-box');
  check('Card OFF: only "Pay by bank transfer" is shown (no Flutterwave)', t.includes('Pay by bank transfer') && !t.includes('Continue to payment'), t.slice(0, 200));
  const r = await buyer.evaluate(async () => { try { await API.fn('payments-init', {purpose:'TOPUP', amount_kobo:500000}); return 'ok'; } catch (e) { return e.message; } });
  check('Card OFF: the server refuses a Flutterwave payment even if someone forces it', /switched off/i.test(r), r);
  await buyer.click('#sheet-box [data-act=close]');
  await twice(admin, '[data-act=cardpay][data-v="1"]');
  check('Admin switches card payments back ON', /ON/.test(await toast(admin)) && sql(`select card_payments_enabled from platform_settings`) === 't');
});

await step('buy 3 months with a start date', async () => {
  fund('buyer@subsplit.ng', 2000000);
  await buyer.goto(B); await buyer.waitForSelector('#feed .card');
  await buyer.click(`#feed .card:has-text("@${ownU}") [data-act=join]`); await buyer.waitForSelector('#j-start');
  await buyer.click('[data-act=jlen][data-v="3"]');
  const day = lagosDay(5);
  await buyer.fill('#j-start', day); await buyer.dispatchEvent('#j-start', 'change');
  const t = await buyer.textContent('#sheet-box');
  check('3 months: ₦2,700 × 3 + ₦200 = ₦8,300, 90 days, with an end date', t.includes('₦8,300') && t.includes('3 months · 90 days') && (await buyer.textContent('#j-end')).trim().length > 5, t.slice(0, 400));
  await buyer.screenshot({ path: SHOTS + '/9-confirm-months.png' });
  await buyer.click('[data-act=payWallet]');
  check('Paid from the wallet for 3 months', /3 months/.test(await toast(buyer)));
  const rows = sql(`select count(*) || '|' || min(to_char(starts_at at time zone 'Africa/Lagos', 'YYYY-MM-DD')) from memberships m join profiles p on p.id = m.buyer_id join listings l on l.id = m.listing_id join profiles h on h.id = l.host_id where p.email = 'buyer@subsplit.ng' and h.email = 'owner@subsplit.ng'`);
  check('3 monthly rows, starting on the chosen day', rows === `3|${day}`, rows);
  await buyer.click('#sheet-box [data-act=close]').catch(() => {});
  await buyer.click('.nav [data-v=mysubs]'); await buyer.waitForSelector('h1:has-text("My Subs")');
  const card = await buyer.textContent(`.card:has-text("@${ownU}")`);
  check('My Subs shows the reserved seat with its start date', card.includes('Starts') && card.includes('reserved'), card.slice(0, 200));
  await buyer.check(`.card:has-text("@${ownU}") [data-act2=autorenew]`);
  check('Auto-renew switch works', /Auto-renew is on/.test(await toast(buyer)) && sql(`select bool_and(auto_renew) from memberships m join profiles p on p.id = m.buyer_id join listings l on l.id = m.listing_id join profiles h on h.id = l.host_id where p.email = 'buyer@subsplit.ng' and h.email = 'owner@subsplit.ng'`) === 't');
  await buyer.screenshot({ path: SHOTS + '/10-mysubs-months.png' });
});

const ren = await newPage(); PAGES.ren = ren;
await step('member renews from the "Will you renew?" question', async () => {
  await signUp(ren, 'Remi Renew', 'remi@subsplit.ng');
  const lid = hostNf();
  sql(`update listings set seats_offered = 4 where id = '${lid}'`);
  fund('remi@subsplit.ng', 3000000);
  const j = await ren.evaluate(async (id) => { try { return (await API.rpc('join_with_wallet', {p_listing:id, p_contact:'', p_months:1})).membership_id; } catch (e) { return 'ERR ' + e.message; } }, lid);
  check('Remi joins Hannah\'s Netflix for 1 month', !String(j).startsWith('ERR'), j);
  sql(`update memberships set starts_at = now() - interval '28 days', ends_at = now() + interval '2 days', release_at = now() + interval '2 days' where id = '${j}'`);
  await ren.goto(B); await ren.waitForSelector('.hero'); await ren.click('.nav [data-v=mysubs]'); await ren.waitForSelector('h1:has-text("My Subs")');
  check('2 days before the end the card asks "Will you renew it?"', (await ren.textContent('main')).includes('Will you renew it?'));
  await ren.screenshot({ path: SHOTS + '/11-ask-renew.png' });
  await ren.click('[data-act=renewSheet]'); await ren.waitForSelector('#rn-sum');
  await ren.click('[data-act=rnlen][data-v="3"]');
  const t = await ren.textContent('#sheet-box');
  check('Renew sheet: 3 × ₦2,700 + ₦200 = ₦8,300', t.includes('₦8,300') && t.includes('3 × ₦2,700'), t.replace(/\s+/g, ' ').slice(0, 300));
  await ren.click('[data-act=renewNow]');
  check('Renewed for 3 months', /Renewed/.test(await toast(ren)) && sql(`select count(*) from memberships m join profiles p on p.id = m.buyer_id where p.email = 'remi@subsplit.ng'`) === '4');
  check('Card now says "Paid until" with 3 more months', /Paid until/.test(await ren.textContent('main')) && (await ren.textContent('main')).includes('3 more months'));
});

await step('member says "I won\'t renew"', async () => {
  sql(`with x as (select m.id, (select max(ends_at) from memberships y where y.order_ref = m.order_ref) - (now() + interval '2 days') d
        from memberships m join profiles p on p.id = m.buyer_id join listings l on l.id = m.listing_id join profiles h on h.id = l.host_id
        where p.email = 'buyer@subsplit.ng' and h.email = 'owner@subsplit.ng')
       update memberships m set starts_at = m.starts_at - x.d, ends_at = m.ends_at - x.d, release_at = m.ends_at - x.d from x where x.id = m.id`);
  sql(`select release_due_escrow()`);
  await buyer.goto(B); await buyer.waitForSelector('.hero'); await buyer.click('.nav [data-v=mysubs]'); await buyer.waitForSelector('h1:has-text("My Subs")');
  const c = `.card:has-text("@${ownU}")`;
  check('Buyer with auto-renew on is not nagged, the switch shows ON', (await buyer.isChecked(`${c} [data-act2=autorenew]`)));
  await buyer.uncheck(`${c} [data-act2=autorenew]`); await toast(buyer);
  check('After switching auto-renew off, the question appears', (await buyer.textContent(c)).includes('Will you renew it?'));
  await buyer.click(`${c} [data-act=noRenew]`);
  check('"I won\'t renew" is saved and the host is told', /ends on/.test(await toast(buyer))
    && sql(`select renew_choice from memberships m join profiles p on p.id = m.buyer_id where p.email = 'buyer@subsplit.ng' and m.status = 'ACTIVE' and not m.renewed and m.ends_at > now() order by ends_at desc limit 1`) === 'NO'
    && +sql(`select count(*) from notifications n join profiles p on p.id = n.user_id where p.email = 'owner@subsplit.ng' and n.title like '%will not renew%'`) >= 1);
  check('Card shows "You chose not to renew" with an undo', (await buyer.textContent(c)).includes('You chose not to renew'));
});

await step('host "Will you renew your plan?"', async () => {
  const lid = hostNf();
  sql(`update listings set host_paid_until = now() + interval '3 days' where id = '${lid}'`);
  await host.goto(B); await host.waitForSelector('.hero'); await host.click('.nav [data-v=mysubs]'); await host.click('[data-act=subs][data-v=hosting]');
  check('Host card asks "Will you renew your Netflix plan?"', (await host.textContent(NF)).includes('Will you renew your Netflix plan?'));
  await host.screenshot({ path: SHOTS + '/12-host-renew.png' });
  await host.click(`${NF} [data-act=hostRenew][data-v="1"]`);
  check('"I will renew": confirmed for another month', /confirmed/.test(await toast(host)) && sql(`select host_paid_until > now() + interval '30 days' from listings where id = '${lid}'`) === 't');
  sql(`update listings set host_paid_until = now() + interval '3 days' where id = '${lid}'`);
  await host.goto(B); await host.waitForSelector('.hero'); await host.click('.nav [data-v=mysubs]'); await host.click('[data-act=subs][data-v=hosting]');
  await host.click(`${NF} [data-act=hostNoRenew]`); await host.waitForSelector('text=Not renewing?');
  check('"I won\'t renew" explains what happens first', (await host.textContent('#sheet-box')).includes('Later months are refunded'));
  await host.click('#sheet-box [data-act=hostRenew][data-v="0"]');
  check('Listing stops taking members', /No new members/.test(await toast(host)) && sql(`select status || ':' || host_stopping from listings where id = '${lid}'`) === 'PAUSED:true');
  check('Remi\'s months after the host\'s end date were refunded (2 of them)', sql(`select count(*) from memberships m join profiles p on p.id = m.buyer_id where p.email = 'remi@subsplit.ng' and m.status = 'REFUNDED'`) === '2');
  check('Remi was told the host is not renewing', +sql(`select count(*) from notifications n join profiles p on p.id = n.user_id where p.email = 'remi@subsplit.ng' and n.type = 'HOST_NOT_RENEWING'`) === 1);
  await host.click(`${NF} [data-act=hostRenew][data-v="1"]`);
  check('"I changed my mind" opens the listing again', /confirmed/.test(await toast(host)) && sql(`select status || ':' || host_stopping from listings where id = '${lid}'`) === 'LIVE:false');
});

await step('admin moves a member to another plan', async () => {
  await admin.click('.side [data-v=memberships]'); await admin.waitForSelector('h1:has-text("Memberships")');
  const mid = sql(`select m.id from memberships m join profiles p on p.id = m.buyer_id where p.email = 'remi@subsplit.ng' and m.status = 'ACTIVE' and m.starts_at <= now() order by m.starts_at limit 1`);
  await admin.click(`[data-act=membership][data-id="${mid}"]`); await admin.waitForSelector('[data-act=movesheet]');
  await admin.click('[data-act=movesheet]'); await admin.waitForSelector('#mv-to');
  const opt = await admin.evaluate((u) => [...document.querySelectorAll('#mv-to option')].find(o => o.textContent.includes('@' + u)).value, ownU);
  await admin.selectOption('#mv-to', opt); await admin.waitForFunction(() => /Unused part credited/.test(document.querySelector('#mv-quote').textContent));
  const q = await admin.textContent('#mv-quote');
  check('Quote shows the credit, the new cost and the difference (same price: ₦0)', q.includes('Unused part credited') && q.includes('New plan, same days') && /Difference₦0/.test(q.replace(/\s+/g, '')), q.replace(/\s+/g, ' '));
  await admin.uncheck('#mv-payold'); await admin.waitForFunction(() => /Left over/.test(document.querySelector('#mv-quote').textContent));
  check('Unticking "pay the old host" credits the whole current month: change goes to the wallet', (await admin.textContent('#mv-quote')).includes('Left over'));
  await admin.check('#mv-payold'); await admin.waitForFunction(() => !/Left over/.test(document.querySelector('#mv-quote').textContent));
  await admin.screenshot({ path: SHOTS + '/13-admin-move.png' });
  await admin.click('#f-move [type=submit]');
  check('Moved at once (no difference to pay)', /Moved/.test(await toast(admin)));
  check('Remi is now in the admin\'s Netflix plan with the same end date', sql(`select count(*) from memberships m join profiles p on p.id = m.buyer_id join listings l on l.id = m.listing_id join profiles h on h.id = l.host_id
     where p.email = 'remi@subsplit.ng' and h.email = 'owner@subsplit.ng' and m.status = 'ACTIVE'`) === '2'
    && sql(`select count(*) from memberships m join profiles p on p.id = m.buyer_id join listings l on l.id = m.listing_id join profiles h on h.id = l.host_id
     where p.email = 'remi@subsplit.ng' and h.email = 'host@subsplit.ng' and m.status = 'ACTIVE' and m.ends_at > now()`) === '0');
  check('Remi was told', +sql(`select count(*) from notifications n join profiles p on p.id = n.user_id where p.email = 'remi@subsplit.ng' and n.type = 'SEAT_MOVED'`) === 1);
  check('Ledger still balanced after the move', sql(`select count(*) from wallet_accounts a left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) t on t.account_id = a.id where a.balance_kobo <> coalesce(t.s, 0)`) === '0');
});

await step('creators: code, link, dashboard, payout', async () => {
  const hu = sql(`select username from profiles where email = 'host@subsplit.ng'`);
  await admin.click('.side [data-v=creators]'); await admin.waitForSelector('h1:has-text("Creators")');
  await admin.click('[data-act=creator]'); await admin.waitForSelector('#f-creator');
  await admin.fill('#cr-user', hu); await admin.fill('#cr-code', 'Hannah'); await admin.fill('#cr-val', '5');
  await admin.selectOption('#cr-bank', 'Kuda'); await admin.fill('#cr-acct', '2012345678'); await admin.fill('#cr-name', 'Hannah Host');
  check('Link preview follows the code', (await admin.textContent('#cr-slug')).trim() === 'hannah');
  await admin.click('#f-creator [type=submit]');
  check('Admin adds a creator with code HANNAH', /Creator added/.test(await toast(admin)) && sql(`select code || '|' || commission_bps || '|' || bank_name from creators`) === 'HANNAH|500|Kuda');
  const fan = await newPage(); PAGES.fan = fan;
  await fan.goto(B + '/hannah'); await fan.waitForSelector('#a-ref');
  check('splitsub.app/hannah opens sign-up with the code filled in', (await fan.inputValue('#a-ref')) === 'HANNAH');
  await fan.fill('#a-name', 'Funmi Fan'); await fan.fill('#a-phone', '08031234567'); await fan.fill('#a-email', 'funmi@subsplit.ng'); await fan.fill('#a-pass', 'password123');
  await fan.click('#f-signup [type=submit]'); await toast(fan);
  check('The fan counts for the creator', sql(`select count(*) from referrals r join profiles p on p.id = r.referrer_id join profiles f on f.id = r.referred_id where p.email = 'host@subsplit.ng' and f.email = 'funmi@subsplit.ng' and r.code = 'HANNAH'`) === '1');
  fund('funmi@subsplit.ng', 1000000);
  const lid = sql(`select l.id from listings l join profiles h on h.id = l.host_id where h.email = 'owner@subsplit.ng' and l.status = 'LIVE' limit 1`);
  sql(`update listings set seats_offered = 4 where id = '${lid}'`);
  const j = await fan.evaluate(async (id) => { try { return (await API.rpc('join_with_wallet', {p_listing:id, p_contact:'', p_months:1})).membership_id; } catch (e) { return 'ERR ' + e.message; } }, lid);
  check('Fan buys a seat: 5% commission waits in escrow', !String(j).startsWith('ERR') && sql(`select amount_kobo || '|' || status from creator_earnings`) === '13500|PENDING', j + ' ' + sql(`select coalesce(string_agg(amount_kobo || '|' || status, ','), '-') from creator_earnings`));
  await host.goto(B); await host.waitForSelector('.hero'); await host.click('.nav [data-v=account]');
  const acc = await host.textContent('main');
  check('Creator sees their dashboard: code, link, 1 sign-up, ₦135 waiting', acc.includes('Creator dashboard') && acc.includes('HANNAH') && acc.includes('/hannah') && acc.includes('₦135'), acc.slice(0, 200));
  await host.screenshot({ path: SHOTS + '/14-creator-dashboard.png', fullPage: true });
  sql(`update memberships set release_at = now() - interval '1 minute' where id = '${j}'`); sql(`select release_due_escrow()`);
  await admin.click('.side [data-v=creators]'); await admin.waitForSelector('h1:has-text("Creators")');
  await twice(admin, '[data-act=preppay]');
  await admin.waitForFunction(() => /payout\(s\) ready/.test(document.getElementById('toast').textContent), null, { timeout: 10000 });
  check('Month-end payout prepared', sql(`select count(*) || '|' || sum(amount_kobo) from creator_payouts where status = 'DUE'`) === '1|13500');
  await admin.waitForSelector('[data-act=cpay][data-v=WALLET]');
  check('Payout card shows the creator\'s bank details', (await admin.textContent('main')).includes('2012345678'));
  await admin.screenshot({ path: SHOTS + '/15-admin-creators.png', fullPage: true });
  const before = wallet('host@subsplit.ng');
  await twice(admin, '[data-act=cpay][data-v=WALLET]');
  await admin.waitForFunction(() => /creator's wallet/.test(document.getElementById('toast').textContent), null, { timeout: 10000 });
  check('"Pay to wallet" adds ₦135 to the creator\'s wallet', wallet('host@subsplit.ng') - before === 13500 && sql(`select status || ':' || method from creator_payouts`) === 'PAID:WALLET');
  await fan.close();
});

await step('bulk messages: email, SMS, WhatsApp', async () => {
  await admin.click('.side [data-v=messages]'); await admin.waitForSelector('h1:has-text("Bulk messages")');
  check('Email is shown as connected', (await admin.textContent('main')).includes('Email is connected'));
  await admin.fill('#bk-to', 'ada@gmail.com\nnot-an-email\nbounce@test.ng\nADA@gmail.com');
  await admin.fill('#bk-subj', 'SplitSub is live'); await admin.fill('#bk-msg', 'Split premium subscriptions and pay only for your seat.\nsplitsub.app');
  await twice(admin, '#f-bulk [type=submit]');
  await admin.waitForSelector('#bk-progress .tip.good, #bk-progress .tip.bad', { timeout: 20000 });
  const pr = await admin.textContent('#bk-progress');
  check('Email: 1 sent, 1 failed (bad address), invalid one skipped, duplicate removed', pr.includes('1 sent') && pr.includes('1 failed'), pr);
  await admin.screenshot({ path: SHOTS + '/16-admin-bulk.png', fullPage: true });
  await admin.waitForTimeout(1700);
  await admin.click('[data-act=filter][data-k=ch][data-v=SMS]'); await admin.waitForSelector('#bk-to');
  await admin.fill('#bk-to', '0803 123 4567\n+2348050000000');
  await admin.fill('#bk-msg', 'SplitSub is live! Split Netflix and more. splitsub.app');
  await twice(admin, '#f-bulk [type=submit]');
  await admin.waitForSelector('#bk-progress .tip.good, #bk-progress .tip.bad', { timeout: 20000 });
  check('SMS: 1 sent, 1 failed', (await admin.textContent('#bk-progress')).includes('1 sent'));
  await admin.waitForTimeout(1700);
  await admin.click('[data-act=filter][data-k=ch][data-v=WHATSAPP]'); await admin.waitForSelector('#bk-to');
  await admin.fill('#bk-to', '08039999999\n08051112222\n08061112222');
  await admin.fill('#bk-msg', 'Hello from SplitSub.\nYour seat is waiting.');
  await twice(admin, '#f-bulk [type=submit]');
  await admin.waitForSelector('#bk-progress .tip.good, #bk-progress .tip.bad', { timeout: 20000 });
  check('WhatsApp: 2 sent, 1 failed (not on WhatsApp)', (await admin.textContent('#bk-progress')).includes('2 sent'));
  const sent = await (await fetch(B + '/test/sent')).json();
  check('Providers got the right messages: email subject, SMS sender, WhatsApp template (no new lines inside)',
    sent.some(x => x.channel === 'EMAIL' && x.to === 'ada@gmail.com' && x.subject === 'SplitSub is live')
    && sent.some(x => x.channel === 'SMS' && x.to === '2348031234567' && x.from === 'SplitSub')
    && sent.some(x => x.channel === 'WHATSAPP' && x.template === 'splitsub_update' && !/\n/.test(x.text)), JSON.stringify(sent).slice(0, 300));
  await admin.waitForTimeout(1700);
  check('History lists the 3 jobs with counts', +sql(`select count(*) from broadcast_jobs where status = 'DONE'`) === 3);
  const r = await buyer.evaluate(async () => { try { await API.fn('bulk-send', {job_id:'11111111-1111-4111-8111-111111111111', channel:'EMAIL'}); return 'ok'; } catch (e) { return e.message; } });
  check('A normal user cannot send bulk messages', /admins only|not allowed/i.test(r), r);
});

check('No JavaScript errors in either app', errors.length === 0, errors.slice(0, 5).join(' | '));
await browser.close();
for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '  -> ' + r.detail}`);
console.log(`\n${results.filter(r => r.ok).length} passed, ${results.filter(r => !r.ok).length} failed`);
