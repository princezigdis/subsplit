// Admin: remove an account.
//  * No money / order history  -> everything is removed (wallet rows, profile, login).
//  * Has history               -> records stay (the ledger must stay complete), but name, phone, email and contact
//                                 details are erased and the login is blocked for good.
// Every permission check happens in the database (admin_close_account_plan, called with the admin's own token).
const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const SUPABASE_URL = env("SUPABASE_URL");
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
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const reply = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function rpc(name: string, args: unknown, headers: Record<string, string>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, { method: "POST", headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const data = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, data };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "Please sign in first." }, 401);
  let b: { user_id?: string; confirm?: string; note?: string } = {};
  try { b = await req.json(); } catch { /* empty */ }
  if (!b.user_id || !UUID.test(b.user_id)) return reply({ error: "Missing user." }, 400);
  const id = b.user_id;

  // 1. permission + safety checks, run as the signed-in admin
  const anon = req.headers.get("apikey") || env("SUPABASE_ANON_KEY");
  const asAdmin = { apikey: anon, Authorization: `Bearer ${token}` };
  const plan = await rpc("admin_close_account_plan", { p_id: id, p_confirm: b.confirm ?? "" }, asAdmin);
  if (!plan.ok) return reply({ error: plan.data?.message || "Not allowed." }, plan.status === 401 || plan.status === 403 ? 401 : 400);
  const username: string = plan.data?.username ?? "";
  let mode: string = plan.data?.mode === "REMOVE" ? "REMOVE" : "CLOSE";

  // 2a. nothing to keep -> remove completely
  if (mode === "REMOVE") {
    const w = await fetch(`${SUPABASE_URL}/rest/v1/wallet_accounts?owner_id=eq.${id}`, { method: "DELETE", headers: { ...SERVER } });
    const u = w.ok ? await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, { method: "DELETE", headers: { ...SERVER } }) : null;
    if (!w.ok || !u || !u.ok) mode = "CLOSE"; // something still references this account: keep the records instead
  }

  // 2b. keep the records, erase the personal details, block the login
  if (mode === "CLOSE") {
    const a = await rpc("account_anonymize", { p_id: id }, { ...SERVER, "Content-Type": "application/json" });
    if (!a.ok) return reply({ error: "Could not erase the account details. Nothing was changed. Try again." }, 502);
    const ban = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, {
      method: "PUT", headers: { ...SERVER, "Content-Type": "application/json" },
      body: JSON.stringify({ email: `removed-${id}@splitsub.invalid`, email_confirm: true, ban_duration: "876000h", user_metadata: {} }),
    });
    if (!ban.ok) return reply({ error: "Details were erased but the login could not be blocked. Press delete again to finish." }, 502);
  }

  // 3. audit trail (as the admin)
  await rpc("admin_close_account_log", { p_id: id, p_mode: mode, p_username: username, p_note: b.note ?? "" }, asAdmin);
  return reply({ ok: true, mode: mode === "REMOVE" ? "REMOVED" : "CLOSED" });
});
