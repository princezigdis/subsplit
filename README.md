# SubSplit — production structure

A subscription-sharing marketplace for Nigeria (₦). Customers join seats on family/team plans; hosts share plans they own; SubSplit controls prices, seats, markup and the 10% fee; a separate admin dashboard runs the marketplace.

**Status:** the code is complete and tested locally (see "Tests"). It is **not live yet**. It goes live after the setup steps below. These need your own accounts: Supabase, Paystack, hosting and a domain.

---

## 1. Project structure

```
subsplit-pro/
├── frontend/                 Customer app  →  https://yourdomain.com/
│   ├── index.html            Explore · My Subs · Wallet · Account (no admin code)
│   ├── config.js             Your Supabase URL + publishable key (public, safe)
│   ├── api.js                Talks to Supabase (auth, database, storage, functions)
│   ├── logo.svg, logo-mark.svg
├── admin/                    Admin dashboard →  https://yourdomain.com/admin/
│   └── index.html            Uses ../config.js and ../api.js
├── backend/functions/        Supabase Edge Functions (server code, holds Paystack secret)
│   ├── payments-init/        Starts a Paystack payment. Amount decided by the database
│   ├── payments-verify/      Verifies with Paystack, then credits once
│   └── paystack-webhook/     Signed Paystack webhook (backup), credits once
├── database/                 Run in Supabase SQL Editor, in order
│   ├── 001_schema.sql        Tables, ledger, rules, RLS, all business functions
│   ├── 002_storage.sql       Private "host-proofs" bucket + policies
│   ├── 003_seed_services.sql Starting services & plans (edit in Admin → Services)
│   ├── 004_cron.sql          Background jobs (release earnings, reminders)
│   └── 005_make_admin.sql    Makes YOUR account the first admin
└── tests/                    Local test kit (not deployed)
    ├── security_tests.sql    90 database checks (security checklist + money)
    ├── e2e.mjs               49 browser checks of both apps
    ├── local-supabase.mjs    Local stand-in for Supabase + fake Paystack
    ├── supabase_stub.sql     Minimal auth/storage schemas for local Postgres
    └── run-all.sh
```

**What goes online (e.g. GitHub Pages repo):** `index.html`, `config.js`, `api.js`, `logo.svg`, `logo-mark.svg` at the root, and `admin/index.html` in an `admin` folder.

---

## 2. How the rules are enforced

| Rule | Where it is enforced |
|---|---|
| Normal price, seat limit, markup range, access type, duration | `service_plans` table, edited only through `admin_save_plan` (admin-only) |
| Host markup 10–30% | CHECK constraints + `host_create_listing` / `host_update_listing` |
| Seat price | `_seat_price()` = (normal price × (100 + markup)%) ÷ platform seats, rounded to ₦1. Computed in the database every time, never sent by the browser |
| 10% platform fee | `platform_fee_bps()` returns 1000. Fixed in SQL; no admin setting |
| No overselling | `_join_check` locks the listing row (`FOR UPDATE`) before counting seats; unique index blocks duplicate seats |
| Wallet / ledger | Balances change only in `_post()`, which writes a `wallet_transactions` row. `admin_ledger_check()` proves balances = ledger |
| Payments | Edge Functions verify with Paystack using the secret key; `payment_complete` is idempotent per reference and only callable by the service role |
| Admin access | `admin_users` table (no browser can write it). Every `admin_*` function calls `_need_admin()` → error 42501 = HTTP 403 |
| Private data | RLS: users read only their own rows; login details (`listing_access`) only for host, paying members, admins; host proofs in a private bucket |
| Audit | Every admin action writes `admin_audit_logs` with old/new values |

Money is stored as integer **kobo** (₦1 = 100 kobo) everywhere.

Earnings flow:
1. A member pays a seat. Their wallet goes down by the seat price, and the host's **Pending** goes up by 90% of it.
2. When the period ends, the host's Pending moves to **Available** and the 10% goes to the platform account.
3. If the member reports a problem, the money stays in Pending until an admin refunds the member (fully or partly) or releases it to the host.

---

## 3. Keys and environment variables

| Where | Name | Value | Secret? |
|---|---|---|---|
| `frontend/config.js` | `SUPABASE_URL` | `https://<project>.supabase.co` | Public |
| `frontend/config.js` | `SUPABASE_PUBLISHABLE_KEY` | Project Settings → API Keys → publishable (or legacy anon) | Public |
| Supabase → Edge Functions → Secrets | `PAYSTACK_SECRET_KEY` | `sk_test_…` (then `sk_live_…`) | **SECRET** |
| Supabase → Edge Functions → Secrets | `SITE_URL` | Your customer site, e.g. `https://subsplit.ng/` | No |
| Provided automatically to functions | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | — | **SECRET** (never copy anywhere) |

Never put `sk_…` or the service-role/secret key in any website file.

---

## 4. Setup (in order)

1. **Supabase project:** create one at supabase.com (region: Europe is closest to Nigeria).
2. **SQL Editor:** run `001_schema.sql`, then `002_storage.sql`, then `003_seed_services.sql`. Turn on Cron (Integrations → Cron, or Database → Extensions → pg_cron), then run `004_cron.sql`.
3. **Edge Functions:** deploy three functions with these exact names: `payments-init`, `payments-verify`, `paystack-webhook`. In each one's settings, turn **off** "Verify JWT". Each function checks things itself.
4. **Secrets:** add `PAYSTACK_SECRET_KEY` and `SITE_URL`.
5. **Paystack:** set the Webhook URL to `https://<project>.supabase.co/functions/v1/paystack-webhook` (test mode first).
6. **config.js:** add your Supabase URL and publishable key.
7. **Host the site:** upload the files listed in section 1. GitHub Pages, Netlify or Vercel all work.
8. **Supabase Auth → URL Configuration:** set Site URL to your site, and add both `https://yoursite/` and `https://yoursite/admin/` to Redirect URLs.
9. **Your account:** create it on the customer site. Then put your email in `005_make_admin.sql` and run it.
10. **Admin → Services:** check every price. Seed prices are starting values only.
11. **Full test:** run the whole flow with Paystack **test** keys: list a plan, approve it, join with a test card, report a problem, refund, withdraw.
12. **Go live:** complete Paystack business activation, switch to the `pk_live`/`sk_live` keys and set the live webhook URL. Set up custom email sending under Auth → Emails (SMTP). Supabase's built-in sender only sends a few emails per hour.

**Admin on a separate subdomain (optional):** deploy `admin/index.html` with copies of `config.js` and `api.js` next to it (change `../` to `./`). Security doesn't change; the database enforces it either way.

---

## 5. Security checklist (all PASS in local tests)

| # | Attempt | Result | Test |
|---|---|---|---|
| 1 | Normal user opens /admin | Access denied, no data | e2e |
| 2 | Normal user calls admin API (dashboard, users, refunds, payouts, settings, ledger, audit) | 403 / denied | sql 1/2, 2c–2h |
| 3 | Normal user changes a service price or seat limit | Permission denied | sql 3, 3b |
| 4 | Host changes normal price | Denied (table and API) | sql 4, 4b, 4c |
| 5 | Host exceeds seat limit | Rejected | sql 5 |
| 6 | Host markup above 30% (or below 10%) | Rejected | sql 6, 6b, 6c + e2e |
| 7 | Buy an already-filled seat (incl. two buyers at once) | Rejected; loser not charged | sql 7 + race test |
| 8 | Duplicate membership | Rejected | sql 8, 8b + e2e |
| 9 | See another user's wallet/ledger/profile/payments | Nothing returned | sql 9–9d |
| 10 | See another plan's login details | Denied | sql 10, 10b + e2e |
| 11 | Change own wallet balance / write ledger | Permission denied | sql 11–11c |
| 12 | Fake Paystack success from the browser | Denied; unpaid reference not credited | sql 12–12c + e2e |
| 13 | Duplicate webhook / duplicate reference | No double credit | sql 13 + e2e |
| 14 | Make self admin | Denied | sql 14–14d |
| 15 | Manage another host's listing or members | Denied | sql 15–15d |

### Tests

```
PGHOST=/path/to/pg/socket PGPORT=5432 bash tests/run-all.sh
```

This needs Postgres 16, Node 22 and Playwright with Chromium. Latest run: **90/90 database checks, 49/49 end-to-end checks**.

---

## 6. Not included yet

- **Host payouts:** these are manual. The admin pays from the bank or Paystack dashboard, then taps "Mark as paid". Automating them needs Paystack Transfers.
- **Notifications:** in-app only. No email, SMS or WhatsApp messages yet.
- **Legal pages:** no Terms of Service or Privacy Policy pages. Add them before launch.
- **Admin sign-in:** uses a password only. Use a strong one; two-factor login can be added later through Supabase MFA.
- **Prices:** seed prices and some seat limits are starting values. Confirm each in Admin → Services.
