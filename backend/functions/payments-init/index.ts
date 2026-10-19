// SplitSub Edge Function: payments-init  (Flutterwave)
// Starts a Flutterwave payment. The AMOUNT is decided by the database, never by the browser:
//   TOPUP -> amount checked against the platform's min/max
//   SEAT  -> amount = the listing's backend seat price
// Deployed with "Verify JWT" OFF (this function checks the user's login itself).
// Setup check: open https://YOUR-PROJECT.supabase.co/functions/v1/payments-init in a browser.
// Secrets needed: FLUTTERWAVE_SECRET_KEY, SITE_URL (and FLUTTERWAVE_WEBHOOK_HASH for the webhook).
const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const FLW_SECRET = env("FLUTTERWAVE_SECRET_KEY");
const FLW_API = env("FLUTTERWAVE_API_BASE", "https://api.flutterwave.com/v3");
const SITE_URL = env("SITE_URL");

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
    method: "POST",
    headers: { ...SERVER, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await r.text();
  const data = text ? JSON.parse(text) : null;
  if (!r.ok) throw new Error(data?.message || "Database error");
  return data;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  if (req.method === "GET") {
    let database = false;
    try { database = (await rpc("payment_fail", { p_reference: "SETUP-CHECK", p_status: "FAILED", p_note: "" }))?.result === "UNKNOWN"; } catch { /* no access */ }
    const key = FLW_SECRET.startsWith("FLWSECK_TEST") ? "test" : FLW_SECRET.startsWith("FLWSECK-") ? "live"
      : FLW_SECRET ? "wrong key (must start with FLWSECK-)" : "missing";
    const hook = env("FLUTTERWAVE_WEBHOOK_HASH") ? "set" : "missing";
    const ready = database && (key === "test" || key === "live") && /^https:\/\//.test(SITE_URL);
    return reply({ ready, database: database ? "ok" : "not connected", flutterwave_key: key, webhook_hash: hook, site_url: SITE_URL || "missing" });
  }
  if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
  if (!FLW_SECRET || !SITE_URL) return reply({ error: "Payments are not set up yet (missing FLUTTERWAVE_SECRET_KEY or SITE_URL)." }, 500);

  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "Please sign in first." }, 401);
  const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVER.apikey, Authorization: `Bearer ${token}` } });
  if (!who.ok) return reply({ error: "Your session expired. Please sign in again." }, 401);
  const user = await who.json();

  let body: { purpose?: string; amount_kobo?: number; listing_id?: string; contact?: string } = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const purpose = body.purpose === "SEAT" ? "SEAT" : "TOPUP";

  try {
    const paused = await rpc("maintenance_on", {});
    if (paused) return reply({ error: "Payments are paused for maintenance. " + paused }, 503);

    const reference = "SS-" + crypto.randomUUID().replace(/-/g, "").slice(0, 20).toUpperCase();
    const p = await rpc("payment_create", {
      p_user: user.id, p_reference: reference, p_purpose: purpose,
      p_amount_kobo: purpose === "TOPUP" ? Math.round(Number(body.amount_kobo) || 0) : null,
      p_listing: purpose === "SEAT" ? body.listing_id ?? null : null,
      p_contact: String(body.contact ?? "").slice(0, 120),
    });

    // Flutterwave takes the amount in NAIRA (not kobo). It sends the customer back to redirect_url
    // with ?status=...&tx_ref=...&transaction_id=...
    const r = await fetch(`${FLW_API}/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${FLW_SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        tx_ref: reference,
        amount: Number(p.amount_kobo) / 100,
        currency: "NGN",
        redirect_url: SITE_URL,
        customer: { email: p.email || user.email, name: p.full_name || p.username || "SplitSub user" },
        customizations: { title: "SplitSub", description: purpose === "SEAT" ? "Reserve your seat" : "Add money to your wallet", logo: SITE_URL.replace(/\/+$/, "") + "/logo-mark.svg" },
        meta: { user_id: user.id, purpose, listing_id: body.listing_id ?? null },
      }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.status !== "success" || !j.data?.link) {
      await rpc("payment_fail", { p_reference: reference, p_status: "FAILED", p_note: String(j.message || "Flutterwave could not start the payment").slice(0, 200) });
      return reply({ error: "We couldn't start the payment. Please try again." }, 502);
    }
    return reply({ authorization_url: j.data.link, reference, amount_kobo: p.amount_kobo });
  } catch (e) {
    return reply({ error: (e as Error).message }, 400);
  }
});
