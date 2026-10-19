// SplitSub Edge Function: flutterwave-webhook
// Flutterwave calls this when a charge completes, even if the customer closed the page.
// Security: the "verif-hash" header must equal FLUTTERWAVE_WEBHOOK_HASH (the secret hash you set in
// the Flutterwave dashboard), AND we re-check the payment with Flutterwave before crediting anything.
// Deployed with "Verify JWT" OFF. Secrets: FLUTTERWAVE_SECRET_KEY, FLUTTERWAVE_WEBHOOK_HASH
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

const HASH = env("FLUTTERWAVE_WEBHOOK_HASH");
const ok = (b: unknown = { ok: true }, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return ok({ error: "Use POST" }, 405);
  if (!HASH || !FLW_SECRET) return ok({ error: "Webhook is not set up" }, 500);
  const sent = req.headers.get("verif-hash") || "";
  if (!sent || !same(sent, HASH)) return ok({ error: "Invalid signature" }, 401);

  let ev: { event?: string; data?: { tx_ref?: string; id?: number; status?: string } } = {};
  try { ev = await req.json(); } catch { return ok({ ok: true }); }
  const ref = String(ev.data?.tx_ref ?? "");
  if (!/^SS-[A-Za-z0-9]{6,60}$/.test(ref)) return ok({ ok: true });   // not one of ours

  try {
    const r = await fetch(`${FLW_API}/transactions/verify_by_reference?tx_ref=${encodeURIComponent(ref)}`, {
      headers: { Authorization: `Bearer ${FLW_SECRET}` },
    });
    const j = await r.json().catch(() => ({}));
    const tx = j.data;
    if (!r.ok || j.status !== "success" || !tx || String(tx.tx_ref) !== ref) return ok({ ok: true, note: "not confirmed" });
    const st = String(tx.status || "").toLowerCase();
    if (st === "successful" || st === "completed") {
      await rpc("payment_complete", {
        p_reference: ref, p_paid_kobo: Math.round(Number(tx.amount) * 100), p_currency: String(tx.currency || ""),
        p_provider_id: String(tx.id ?? ""), p_channel: String(tx.payment_type ?? ""),
      });
    } else if (st === "failed" || st === "cancelled") {
      await rpc("payment_fail", { p_reference: ref, p_status: st === "cancelled" ? "ABANDONED" : "FAILED", p_note: String(tx.processor_response || st).slice(0, 200) });
    }
    return ok();
  } catch (e) {
    return ok({ error: (e as Error).message }, 500);   // non-200 makes Flutterwave retry
  }
});
