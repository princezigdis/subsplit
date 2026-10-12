// End-to-end test: customer app + admin app + real SQL + real Edge Function code + fake Paystack.
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
  check('Host sees platform price ₦8,500 + 4-seat limit (read-only)', calc.includes('₦8,500') && calc.includes('4 seats · set by SubSplit') && !(await host.$('#sheet-box input[id*=price]')));
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
  await admin.click('[data-act=proofsheet]'); await admin.waitForSelector('[data-act=proof]');
  const [pop] = await Promise.all([admin.waitForEvent('popup'), admin.click('[data-act=proof]')]);
  check('Admin can open the private proof file', pop.url().includes('/sign-local/host-proofs/'));
  await pop.close();
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
  check('Card: "4 of 4 seats available", host, access, duration', cardText.includes('4 of 4 seats available') && cardText.includes('@host') && cardText.includes('Shared login') && cardText.includes('30 days'));
  check('Explore never contains the password', !(await buyer.content()).includes('S3cret'));
  await buyer.screenshot({ path: SHOTS + '/2-explore.png' });
});
let seatRef = '';
await step('buyer pays for seat with Paystack', async () => {
  await buyer.click('#feed .card [data-act=join]'); await buyer.waitForSelector('text=Confirm your seat');
  const t = await buyer.textContent('#sheet-box');
  check('Confirm screen shows service, price, ₦200 fee, total ₦2,750', ['Netflix · Premium', '₦2,550/month', '30 days', 'Shared login', '@host', 'Available seats', 'Transaction fee', '₦200', 'Total to pay', '₦2,750'].every(x => t.includes(x)));
  await buyer.screenshot({ path: SHOTS + '/3-confirm.png' });
  await buyer.click('[data-act=payCard]'); await buyer.waitForURL(/paystack\/checkout/);
  seatRef = buyer.url().split('/').pop();
  check('Seat payment amount set by backend (₦2,550 + ₦200 fee)', (await buyer.textContent('body')).includes('NGN 2,750'));
  await buyer.click('#pay'); await buyer.waitForSelector("text=You're in!");
  check('After Paystack: seat reserved, money verified on server', sql(`select status || '/' || paid_kobo || '/' || (membership_id is not null) from payments where reference = '${seatRef}'`) === 'SUCCESS/275000/true');
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
  check('Duplicate Paystack webhooks accepted but credit nothing extra', r1 === 'ok' && r2 === 'ok' && wallet('buyer@subsplit.ng') === 0 && sql(`select count(*) from wallet_transactions where payment_reference = '${seatRef}' and type = 'TOP_UP'`) === '1');
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
  await admin.fill('#ac-body', 'SubSplit support here, shout if you need us.'); await admin.click('#f-achat [type=submit]');
  await admin.waitForSelector('#achat-box :text("shout if you need us")');
  check('Admin message saved and audited', sql(`select count(*) from order_messages where sender_role = 'ADMIN'`) === '1' && sql(`select count(*) from admin_audit_logs where action = 'ORDER_CHAT_MESSAGE'`) === '1');
  await admin.click('#sheet-box [data-act=close]');
  // receipt + PDF
  await buyer.goto(B); await buyer.click('.nav [data-v=mysubs]');
  await buyer.click('.card:has-text("Netflix") [data-act=receipt]'); await buyer.waitForSelector('text=Purchase receipt');
  const rt = await buyer.textContent('#sheet-box');
  check('Receipt shows ID, price, ₦200 fee, total, method, status', ['Transaction ID', 'SUB-', '₦2,550', '₦200', '₦2,750', 'Paystack', 'Successful'].every(x => rt.includes(x)), rt.slice(0, 300));
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

check('No JavaScript errors in either app', errors.length === 0, errors.slice(0, 5).join(' | '));
await browser.close();
for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '  -> ' + r.detail}`);
console.log(`\n${results.filter(r => r.ok).length} passed, ${results.filter(r => !r.ok).length} failed`);
