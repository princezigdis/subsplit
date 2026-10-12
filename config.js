// =====================================================================
//  SplitSub public configuration (used by the customer app AND the admin app)
//
//  Both values below are SAFE to be public. They only identify your
//  Supabase project. All security is enforced by the database.
//
//  NEVER put any of these here (or anywhere in the website files):
//    - Supabase "service_role" / "secret" key
//    - Paystack SECRET key (sk_...)
//  Those live only in Supabase -> Edge Functions -> Secrets.
// =====================================================================
window.SUBSPLIT_CONFIG = {
  SUPABASE_URL: 'https://merpfrmpxsvtxbkazgdy.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fFAWfVtc9387I1omSVZMSg_IeBIHSxr'   // Project Settings -> API Keys -> "publishable" key
};
