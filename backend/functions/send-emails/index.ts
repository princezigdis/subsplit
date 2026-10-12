// =====================================================================
//  SplitSub Edge Function: send-emails
//  Sends the branded emails queued by the database (email_outbox):
//  purchase confirmation, host new-order, payment confirmation,
//  withdrawal status, dispute, expiry reminder, subscription request
//  added, referral rewards, admin credit.
//  Called every 5 minutes by the database (pg_cron) with a private token.
//  Deployed with "Verify JWT" OFF; it checks the token itself.
//
//  Secrets (Edge Functions -> Secrets):
//    RESEND_API_KEY   from resend.com  (free plan is enough to start)
//    EMAIL_FROM       e.g.  SplitSub <hello@yourdomain.com>
//                     (until you own a domain: SplitSub <onboarding@resend.dev>)
//    SITE_URL         your customer site (used for the button + logo)
//  Emails never contain passwords or access details.
// =====================================================================
const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const RESEND = env("RESEND_API_KEY");
const FROM = env("EMAIL_FROM", "SplitSub <onboarding@resend.dev>");
const SITE = env("SITE_URL").replace(/\/?$/, "/");

function serverHeaders(): Record<string, string> {
  try {
    const keys = JSON.parse(env("SUPABASE_SECRET_KEYS", "{}"));
    const k = keys.default ?? Object.values(keys)[0];
    if (typeof k === "string" && k) return { apikey: k };
  } catch { /* not set */ }
  const legacy = env("SUPABASE_SERVICE_ROLE_KEY");
  return { apikey: legacy, Authorization: `Bearer ${legacy}` };
}
const SERVER = serverHeaders();

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: { ...SERVER, "Content-Type": "application/json" }, body: JSON.stringify(args),
  });
  const t = await r.text();
  const d = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(d?.message || "Database error");
  return d;
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const HEADINGS: Record<string, string> = {
  PAYMENT_SUCCESS: "Payment confirmed", PAYMENT_FAILED: "Payment not completed", SUBSCRIPTION_JOINED: "Purchase confirmed",
  SUBSCRIPTION_RENEWED: "Renewal confirmed", NEW_MEMBER: "You have a new order", ACCESS_AVAILABLE: "Your access is ready",
  EXPIRING: "Your seat ends soon", EXPIRING_HOST: "A member's seat ends soon", EARNING_AVAILABLE: "Earnings ready to withdraw",
  REFUND: "Refund processed", WITHDRAWAL_REQUESTED: "Withdrawal requested", WITHDRAWAL_APPROVED: "Withdrawal approved",
  WITHDRAWAL_PAID: "Withdrawal sent", WITHDRAWAL_REJECTED: "Withdrawal update", DISPUTE_OPENED: "A report was opened",
  DISPUTE_RESOLVED: "Your report was resolved", DISPUTE_PROOF: "Update on your report", LISTING_APPROVED: "Listing update",
  LISTING_REJECTED: "Listing needs changes", LISTING_SUSPENDED: "Listing suspended", REFERRAL_REWARD: "You earned a reward",
  REQUEST_ADDED: "Good news: it's now on SplitSub", REQUEST_DECLINED: "About your request", ADMIN_CREDIT: "Money added to your wallet",
  ADJUSTMENT: "Wallet update", SUPPORT_REPLY: "Support replied", ADMIN_ALERT: "Admin alert",
};

function html(type: string, subject: string, body: string) {
  const h = HEADINGS[type] || subject;
  return `<!doctype html><html><body style="margin:0;background:#f4f3fb;font-family:Arial,Helvetica,sans-serif;color:#1f1d3a">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table width="100%" style="max-width:480px;background:#fff;border-radius:18px;overflow:hidden" cellpadding="0" cellspacing="0">
<tr><td style="background:#5B5BD6;padding:18px 24px"><img src="${SITE}logo-email.png" alt="SplitSub" height="32" style="display:block;border:0"></td></tr>
<tr><td style="padding:24px"><h2 style="margin:0 0 8px;font-size:20px">${esc(h)}</h2>
<p style="margin:0 0 6px;font-weight:bold;font-size:15px">${esc(subject)}</p>
<p style="margin:0 0 20px;font-size:15px;line-height:1.5;color:#44425f">${esc(body)}</p>
<a href="${SITE}" style="display:inline-block;background:#5B5BD6;color:#fff;text-decoration:none;padding:12px 22px;border-radius:12px;font-weight:bold">Open SplitSub</a>
<p style="margin:22px 0 0;font-size:12px;color:#8886a6">We never ask for your password by email. Access details are only shown inside the app.</p>
</td></tr></table></td></tr></table></body></html>`;
}

Deno.serve(async (req: Request) => {
  const token = req.headers.get("x-cron-token") || "";
  let ok = false;
  try { ok = token.length > 10 && (await rpc("email_check_token", { p_token: token })) === true; } catch { /* no access */ }
  if (!ok) return new Response(JSON.stringify({ error: "Not allowed" }), { status: 403, headers: { "Content-Type": "application/json" } });
  if (!RESEND) return new Response(JSON.stringify({ configured: false, note: "RESEND_API_KEY is not set, emails stay queued." }), { headers: { "Content-Type": "application/json" } });

  const items: Array<{ id: number; to: string; type: string; subject: string; body: string }> = await rpc("email_claim", { p_limit: 25 });
  let sent = 0, failed = 0;
  for (const m of items) {
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: FROM, to: [m.to], subject: `SplitSub · ${m.subject}`, html: html(m.type, m.subject, m.body), text: `${m.subject}\n\n${m.body}\n\n${SITE}` }),
      });
      if (!r.ok) throw new Error((await r.text()).slice(0, 200));
      await rpc("email_mark", { p_id: m.id, p_ok: true, p_err: "" }); sent++;
    } catch (e) {
      await rpc("email_mark", { p_id: m.id, p_ok: false, p_err: (e as Error).message }); failed++;
    }
  }
  return new Response(JSON.stringify({ configured: true, sent, failed }), { headers: { "Content-Type": "application/json" } });
});
