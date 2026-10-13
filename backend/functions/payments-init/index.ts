// =====================================================================
//  SplitSub Edge Function: payments-init
//  Starts a Paystack payment. The AMOUNT is decided by the database,
//  never by the browser:
//    TOPUP -> amount checked against the platform's min/max
//    SEAT  -> amount = the listing's backend seat price
//  Deploy: Supabase -> Edge Functions -> Deploy new function -> name it
//  "payments-init" -> paste this file -> Deploy. Turn OFF "Verify JWT"
//  (this function checks the user's login itself, below).
//
//  Secrets needed (Edge Functions -> Secrets):
//    PAYSTACK_SECRET_KEY   sk_test_... or sk_live_...
//    SITE_URL              your customer site, e.g. https://subsplit.ng/
//  (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.)
// =====================================================================

const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");
const PAYSTACK_SECRET = env("PAYSTACK_SECRET_KEY");
const PAYSTACK_API = env("PAYSTACK_API_BASE", "https://api.paystack.co");
const SITE_URL = env("SITE_URL");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Call a database function with the server key (never sent to browsers).
async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await r.text();
  const data = text ? JSON.parse(text) : null;
  if (!r.ok) throw new Error(data?.message || "Database error");
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
  if (!PAYSTACK_SECRET || !SITE_URL) return reply({ error: "Payments are not set up yet (missing PAYSTACK_SECRET_KEY or SITE_URL)." }, 500);

  // 1. Who is paying? Check the login token with Supabase Auth.
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "Please sign in first." }, 401);
  const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${token}` } });
  if (!who.ok) return reply({ error: "Your session expired. Please sign in again." }, 401);
  const user = await who.json();

  let body: { purpose?: string; amount_kobo?: number; listing_id?: string; contact?: string } = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const purpose = body.purpose === "SEAT" ? "SEAT" : "TOPUP";

  try {
    const paused = await rpc("maintenance_on", {});
    if (paused) return reply({ error: "Payments are paused for maintenance. " + paused }, 503);
    // 2. Database records the payment as PENDING and decides the amount.
    const reference = "SS-" + crypto.randomUUID().replace(/-/g, "").slice(0, 20).toUpperCase();
    const p = await rpc("payment_create", {
      p_user: user.id, p_reference: reference, p_purpose: purpose,
      p_amount_kobo: purpose === "TOPUP" ? Math.round(Number(body.amount_kobo) || 0) : null,
      p_listing: purpose === "SEAT" ? body.listing_id ?? null : null,
      p_contact: String(body.contact ?? "").slice(0, 120),
    });

    // 3. Paystack creates the checkout page. Paystack sends the customer back to SITE_URL?reference=...
    const r = await fetch(`${PAYSTACK_API}/transaction/initialize`, {
      method: "POST",
      headers: { Authorization: `Bearer ${PAYSTACK_SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        email: p.email || user.email, amount: p.amount_kobo, currency: "NGN", reference, callback_url: SITE_URL,
        metadata: { user_id: user.id, purpose, listing_id: body.listing_id ?? null },
      }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.status || !j.data?.authorization_url) {
      await rpc("payment_fail", { p_reference: reference, p_status: "FAILED", p_note: j.message || "Paystack could not start the payment" });
      return reply({ error: "We couldn't start the payment. Please try again." }, 502);
    }
    return reply({ authorization_url: j.data.authorization_url, reference, amount_kobo: p.amount_kobo });
  } catch (e) {
    return reply({ error: (e as Error).message }, 400);
  }
});
