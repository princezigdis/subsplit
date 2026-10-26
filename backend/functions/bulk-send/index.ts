// =====================================================================
//  SplitSub Edge Function: bulk-send
//  Sends an admin's bulk message (email, SMS or WhatsApp) in small batches.
//  The admin page calls it again and again until every message is sent.
//  Every database call uses the ADMIN'S OWN LOGIN, so only admins can ever send.
//  Deployed with "Verify JWT" OFF (it checks the admin itself through the database).
//
//  Secrets (Supabase -> Edge Functions -> Secrets). Only add the ones you use:
//    EMAIL     RESEND_API_KEY, EMAIL_FROM  (already set for the normal emails)
//    SMS       TERMII_API_KEY, TERMII_SENDER_ID (your approved sender name, e.g. SplitSub),
//              TERMII_BASE_URL (from your Termii dashboard, e.g. https://v3.api.termii.com),
//              TERMII_CHANNEL (optional: "generic" default, or "dnd" if Termii enabled it for you)
//    WHATSAPP  WHATSAPP_TOKEN (permanent access token), WHATSAPP_PHONE_NUMBER_ID,
//              WHATSAPP_TEMPLATE (an approved template whose body has ONE variable {{1}}),
//              WHATSAPP_TEMPLATE_LANG (optional, default "en")
//  Open the function URL in a browser to see which channels are connected (no secrets are shown).
// =====================================================================
const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const SITE = env("SITE_URL", "https://splitsub.app/").replace(/\/?$/, "/");
const RESEND = env("RESEND_API_KEY");
const RESEND_BASE = env("RESEND_BASE_URL", "https://api.resend.com");
const FROM = env("EMAIL_FROM", "SplitSub <onboarding@resend.dev>");
const TERMII_KEY = env("TERMII_API_KEY");
const TERMII_SENDER = env("TERMII_SENDER_ID");
const TERMII_BASE = env("TERMII_BASE_URL", "https://v3.api.termii.com").replace(/\/+$/, "");
const TERMII_CHANNEL = env("TERMII_CHANNEL", "generic");
const WA_TOKEN = env("WHATSAPP_TOKEN");
const WA_PHONE = env("WHATSAPP_PHONE_NUMBER_ID");
const WA_TEMPLATE = env("WHATSAPP_TEMPLATE");
const WA_LANG = env("WHATSAPP_TEMPLATE_LANG", "en");
const GRAPH = env("WHATSAPP_GRAPH_URL", "https://graph.facebook.com/v21.0").replace(/\/+$/, "");
const GAP_MS = Number(env("BULK_GAP_MS", "550"));     // stay under the providers' speed limits

const READY = {
  EMAIL: !!RESEND,
  SMS: !!(TERMII_KEY && TERMII_SENDER),
  WHATSAPP: !!(WA_TOKEN && WA_PHONE),
};
const SETUP: Record<string, string> = {
  EMAIL: "Email is not connected. Add RESEND_API_KEY in Supabase -> Edge Functions -> Secrets.",
  SMS: "SMS is not connected yet. Add TERMII_API_KEY and TERMII_SENDER_ID (and TERMII_BASE_URL) in Supabase -> Edge Functions -> Secrets.",
  WHATSAPP: "WhatsApp is not connected yet. Add WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID and WHATSAPP_TEMPLATE in Supabase -> Edge Functions -> Secrets.",
};

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const reply = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function rpc(name: string, args: unknown, headers: Record<string, string>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, { method: "POST", headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const data = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, data };
}

function emailHtml(subject: string, message: string) {
  const body = esc(message).replace(/\r?\n/g, "<br>");
  return `<!doctype html><html><body style="margin:0;background:#f4f3fb;font-family:Arial,Helvetica,sans-serif;color:#1f1d3a">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table width="100%" style="max-width:480px;background:#fff;border-radius:18px;overflow:hidden" cellpadding="0" cellspacing="0">
<tr><td style="background:#5B5BD6;padding:18px 24px"><img src="${SITE}logo-email.png" alt="SplitSub" height="32" style="display:block;border:0"></td></tr>
<tr><td style="padding:24px"><h2 style="margin:0 0 12px;font-size:20px">${esc(subject)}</h2>
<p style="margin:0 0 20px;font-size:15px;line-height:1.55;color:#44425f">${body}</p>
<a href="${SITE}" style="display:inline-block;background:#5B5BD6;color:#fff;text-decoration:none;padding:12px 22px;border-radius:12px;font-weight:bold">Open SplitSub</a>
<p style="margin:22px 0 0;font-size:12px;color:#8886a6">You got this message from SplitSub. If you don't want these messages, reply STOP and we will remove you.</p>
</td></tr></table></td></tr></table></body></html>`;
}

type Result = { id: number; ok: boolean; error?: string; final?: boolean };

// A permanent problem (bad address, bad number) is "final": no point trying again.
async function sendOne(channel: string, to: string, subject: string, message: string): Promise<{ ok: boolean; error?: string; final?: boolean }> {
  try {
    if (channel === "EMAIL") {
      const r = await fetch(`${RESEND_BASE}/emails`, {
        method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: FROM, to: [to], subject, html: emailHtml(subject, message), text: `${message}\n\n${SITE}` }),
      });
      if (r.ok) return { ok: true };
      const t = (await r.text()).slice(0, 200);
      return { ok: false, error: t || `Email failed (${r.status})`, final: r.status >= 400 && r.status < 500 && r.status !== 429 };
    }
    if (channel === "SMS") {
      const r = await fetch(`${TERMII_BASE}/api/sms/send`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ api_key: TERMII_KEY, to, from: TERMII_SENDER, sms: message, type: "plain", channel: TERMII_CHANNEL }),
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok && (j.code === "ok" || j.message_id)) return { ok: true };
      return { ok: false, error: String(j.message || j.error || `SMS failed (${r.status})`).slice(0, 200), final: r.status >= 400 && r.status < 500 && r.status !== 429 };
    }
    if (channel === "WHATSAPP") {
      // WhatsApp does not allow new lines or tabs inside a template variable
      const text = message.replace(/[\r\n\t]+/g, " · ").replace(/ {4,}/g, "   ").slice(0, 1000);
      const payload = WA_TEMPLATE
        ? { messaging_product: "whatsapp", to, type: "template",
            template: { name: WA_TEMPLATE, language: { code: WA_LANG }, components: [{ type: "body", parameters: [{ type: "text", text }] }] } }
        : { messaging_product: "whatsapp", to, type: "text", text: { body: message.slice(0, 4000) } };
      const r = await fetch(`${GRAPH}/${WA_PHONE}/messages`, {
        method: "POST", headers: { Authorization: `Bearer ${WA_TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify(payload),
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j.messages && j.messages.length) return { ok: true };
      return { ok: false, error: String(j.error?.message || `WhatsApp failed (${r.status})`).slice(0, 200), final: r.status >= 400 && r.status < 500 && r.status !== 429 };
    }
    return { ok: false, error: "Unknown channel", final: true };
  } catch (e) {
    return { ok: false, error: String((e as Error).message || e).slice(0, 200) };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method === "GET") {
    return reply({ email: READY.EMAIL, sms: READY.SMS, whatsapp: READY.WHATSAPP, sms_sender: TERMII_SENDER || null,
                   whatsapp_template: WA_TEMPLATE || null, whatsapp_mode: WA_TEMPLATE ? "template" : "text" });
  }
  if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "Please sign in first." }, 401);
  let b: { job_id?: string; channel?: string; check?: boolean } = {};
  try { b = await req.json(); } catch { /* empty */ }
  if (b.check) {
    return reply({ email: READY.EMAIL, sms: READY.SMS, whatsapp: READY.WHATSAPP, sms_sender: TERMII_SENDER || null,
                   whatsapp_template: WA_TEMPLATE || null, whatsapp_mode: WA_TEMPLATE ? "template" : "text" });
  }
  if (!b.job_id || !UUID.test(b.job_id)) return reply({ error: "Missing message." }, 400);
  const channel = String(b.channel || "");
  if (!(channel in READY)) return reply({ error: "Pick email, SMS or WhatsApp." }, 400);
  if (!READY[channel as keyof typeof READY]) return reply({ error: SETUP[channel], not_connected: true }, 400);

  const anon = req.headers.get("apikey") || env("SUPABASE_ANON_KEY");
  const asAdmin = { apikey: anon, Authorization: `Bearer ${token}` };
  const limit = channel === "EMAIL" ? 20 : 25;
  const c = await rpc("admin_bulk_claim", { p_job: b.job_id, p_limit: limit }, asAdmin);
  if (!c.ok) return reply({ error: c.data?.message || "Not allowed." }, c.status === 401 || c.status === 403 ? 403 : 400);
  const job = c.data?.job || {};
  if (job.channel && job.channel !== channel) return reply({ error: "This message is for a different channel." }, 400);
  const items: Array<{ id: number; to: string }> = c.data?.items || [];
  const results: Result[] = [];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    const r = await sendOne(channel, it.to, String(job.subject || "SplitSub"), String(job.message || ""));
    results.push({ id: it.id, ...r });
    if (i < items.length - 1 && GAP_MS > 0) await sleep(GAP_MS);
  }
  const m = await rpc("admin_bulk_mark", { p_job: b.job_id, p_results: results }, asAdmin);
  if (!m.ok) return reply({ error: m.data?.message || "Could not save the results." }, 400);
  return reply({ ...m.data, batch: results.length, batch_sent: results.filter((r) => r.ok).length });
});
