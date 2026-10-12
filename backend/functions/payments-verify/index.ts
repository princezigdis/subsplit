// =====================================================================
//  SplitSub Edge Function: payments-verify
//  After Paystack sends the customer back, the website calls this with
//  the payment reference. We ask PAYSTACK directly whether it succeeded
//  (the browser's word is never trusted), then the database credits the
//  wallet ONCE (and reserves the seat for seat payments).
//  Safe to call many times for the same reference.
//  Deploy as "payments-verify". Turn OFF "Verify JWT".
//  Secrets: PAYSTACK_SECRET_KEY
// =====================================================================

const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");
const PAYSTACK_SECRET = env("PAYSTACK_SECRET_KEY");
const PAYSTACK_API = env("PAYSTACK_API_BASE", "https://api.paystack.co");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

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
  if (!PAYSTACK_SECRET) return reply({ error: "PAYSTACK_SECRET_KEY is not set." }, 500);

  let reference = "";
  try { reference = String((await req.json()).reference ?? ""); } catch { /* empty */ }
  if (!/^[A-Za-z0-9._=-]{6,100}$/.test(reference)) return reply({ error: "Missing payment reference." }, 400);

  const r = await fetch(`${PAYSTACK_API}/transaction/verify/${encodeURIComponent(reference)}`, {
    headers: { Authorization: `Bearer ${PAYSTACK_SECRET}` },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.status) return reply({ status: "PENDING", message: "We are still confirming your payment." });

  const tx = j.data || {};
  try {
    if (tx.status === "success") {
      const result = await rpc("payment_complete", {
        p_reference: reference, p_paid_kobo: Number(tx.amount), p_currency: String(tx.currency || ""),
        p_provider_id: String(tx.id ?? ""), p_channel: String(tx.channel ?? ""),
      });
      if (result?.result === "FAILED") return reply({ status: "FAILED", message: "This payment could not be accepted." });
      if (result?.result === "UNKNOWN") return reply({ status: "FAILED", message: "We could not match this payment." }, 404);
      return reply({ status: "SUCCESS", ...result });
    }
    if (tx.status === "failed" || tx.status === "abandoned" || tx.status === "reversed") {
      await rpc("payment_fail", { p_reference: reference, p_status: tx.status === "abandoned" ? "ABANDONED" : "FAILED", p_note: tx.gateway_response || tx.status });
      return reply({ status: tx.status === "abandoned" ? "CANCELLED" : "FAILED", message: "The payment did not go through. No money was taken." });
    }
    return reply({ status: "PENDING", message: "Your bank is still confirming the payment." });
  } catch (e) {
    return reply({ status: "ERROR", message: (e as Error).message }, 500);
  }
});
