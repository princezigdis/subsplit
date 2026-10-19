// SplitSub Edge Function: payments-verify  (Flutterwave)
// After Flutterwave sends the customer back, the website calls this with the payment reference
// (our tx_ref). We ask FLUTTERWAVE directly whether it succeeded (the browser's word is never
// trusted), then the database credits the wallet ONCE. Safe to call many times.
// Deployed with "Verify JWT" OFF. Secrets: FLUTTERWAVE_SECRET_KEY
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
  if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
  if (!FLW_SECRET) return reply({ error: "FLUTTERWAVE_SECRET_KEY is not set." }, 500);

  let reference = "";
  try { reference = String((await req.json()).reference ?? ""); } catch { /* empty */ }
  if (!/^[A-Za-z0-9._=-]{6,100}$/.test(reference)) return reply({ error: "Missing payment reference." }, 400);

  const r = await fetch(`${FLW_API}/transactions/verify_by_reference?tx_ref=${encodeURIComponent(reference)}`, {
    headers: { Authorization: `Bearer ${FLW_SECRET}` },
  });
  const j = await r.json().catch(() => ({}));
  // Not found yet = the customer has not paid (or Flutterwave is still recording it).
  if (!r.ok || j.status !== "success" || !j.data) return reply({ status: "PENDING", message: "We are still confirming your payment." });

  const tx = j.data;
  const st = String(tx.status || "").toLowerCase();
  try {
    if (st === "successful" || st === "completed") {
      if (String(tx.tx_ref) !== reference) return reply({ status: "FAILED", message: "We could not match this payment." }, 404);
      const result = await rpc("payment_complete", {
        p_reference: reference, p_paid_kobo: Math.round(Number(tx.amount) * 100), p_currency: String(tx.currency || ""),
        p_provider_id: String(tx.id ?? ""), p_channel: String(tx.payment_type ?? ""),
      });
      if (result?.result === "FAILED") return reply({ status: "FAILED", message: "This payment could not be accepted." });
      if (result?.result === "UNKNOWN") return reply({ status: "FAILED", message: "We could not match this payment." }, 404);
      return reply({ status: "SUCCESS", ...result });
    }
    if (st === "failed" || st === "cancelled") {
      await rpc("payment_fail", { p_reference: reference, p_status: st === "cancelled" ? "ABANDONED" : "FAILED", p_note: String(tx.processor_response || st).slice(0, 200) });
      return reply({ status: st === "cancelled" ? "CANCELLED" : "FAILED", message: "The payment did not go through. No money was taken." });
    }
    return reply({ status: "PENDING", message: "Your bank is still confirming the payment." });
  } catch (e) {
    return reply({ status: "ERROR", message: (e as Error).message }, 500);
  }
});
