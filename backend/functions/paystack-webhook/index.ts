// =====================================================================
//  SubSplit Edge Function: paystack-webhook
//  Paystack calls this when a payment succeeds (backup in case the
//  customer closes their browser before returning to the site).
//  1. Checks the request really came from Paystack (HMAC SHA-512 signature).
//  2. Asks Paystack again to confirm the payment.
//  3. Database credits it ONCE. Duplicate webhooks change nothing.
//  Deploy as "paystack-webhook". Turn OFF "Verify JWT".
//  In Paystack: Settings -> API Keys & Webhooks -> Webhook URL =
//    https://YOUR-PROJECT.supabase.co/functions/v1/paystack-webhook
//  Secrets: PAYSTACK_SECRET_KEY
// =====================================================================

const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");
const PAYSTACK_SECRET = env("PAYSTACK_SECRET_KEY");
const PAYSTACK_API = env("PAYSTACK_API_BASE", "https://api.paystack.co");

async function hmacSha512Hex(text: string, key: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
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
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  if (!PAYSTACK_SECRET) return new Response("Not configured", { status: 500 });

  const raw = await req.text();
  const signature = req.headers.get("x-paystack-signature") || "";
  if (!signature || !sameText(await hmacSha512Hex(raw, PAYSTACK_SECRET), signature)) {
    return new Response("Invalid signature", { status: 401 });
  }

  let event: { event?: string; data?: { reference?: string } } = {};
  try { event = JSON.parse(raw); } catch { return new Response("Bad JSON", { status: 400 }); }
  if (event.event !== "charge.success" || !event.data?.reference) return new Response("ignored", { status: 200 });

  const reference = event.data.reference;
  // Never trust the webhook body for the amount: re-check with Paystack.
  const r = await fetch(`${PAYSTACK_API}/transaction/verify/${encodeURIComponent(reference)}`, {
    headers: { Authorization: `Bearer ${PAYSTACK_SECRET}` },
  });
  const j = await r.json().catch(() => ({}));
  const tx = j?.data;
  if (!r.ok || !j.status || tx?.status !== "success") return new Response("not successful", { status: 200 });

  try {
    await rpc("payment_complete", {
      p_reference: reference, p_paid_kobo: Number(tx.amount), p_currency: String(tx.currency || ""),
      p_provider_id: String(tx.id ?? ""), p_channel: String(tx.channel ?? ""),
    });
    return new Response("ok", { status: 200 });
  } catch (e) {
    // 500 makes Paystack retry later. payment_complete is safe to repeat.
    return new Response((e as Error).message, { status: 500 });
  }
});
