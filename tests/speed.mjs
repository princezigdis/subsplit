// Page-speed check on a phone-like device: slow 4G + 4x slower CPU. Needs the local test server (tests/local-supabase.mjs) running on :8787
// with the e2e database already filled by run-all.sh. Prints how long until the page is usable.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)(process.env.NODE_PATH + '/playwright');
const B = 'http://localhost:8787';
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
async function measure(label, url, ready, signIn) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }), p = await ctx.newPage();
  const cdp = await ctx.newCDPSession(p);
  await cdp.send('Network.enable');
  let bytes = 0, reqs = 0;
  cdp.on('Network.loadingFinished', e => { bytes += e.encodedDataLength; reqs++; });
  if (signIn) { await p.goto(B); await p.waitForSelector('.hero'); await p.click('.top [data-act=auth]'); await p.fill('#a-email', 'host@subsplit.ng'); await p.fill('#a-pass', 'password123'); await p.click('#f-signin [type=submit]'); await p.waitForSelector('.nav'); }
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 150, downloadThroughput: 1.6 * 1024 * 1024 / 8, uploadThroughput: 750 * 1024 / 8 });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  const runs = [];
  for (let i = 0; i < 5; i++) {
    bytes = 0; reqs = 0; const t = Date.now();
    await p.goto(url, { waitUntil: 'commit' }); await p.waitForSelector(ready, { timeout: 60000 });
    runs.push(Date.now() - t);
  }
  runs.sort((a, b) => a - b);
  console.log(`${label.padEnd(34)} median ${String(runs[2]).padStart(5)} ms   best ${runs[0]} ms   worst ${runs[4]} ms   ${reqs} requests, ${(bytes / 1024).toFixed(0)} KB over the wire (last run)`);
  await ctx.close();
}
console.log('Slow-4G phone (150 ms latency, 1.6 Mbps, CPU 4x slower), 5 loads each:');
await measure('Customer app, signed out (Explore)', B + '/', '.hero');
await measure('Customer app, signed in (Explore)', B + '/', '.nav', true);
await measure('Admin sign-in screen', B + '/admin/', '#f-login');
await browser.close();
