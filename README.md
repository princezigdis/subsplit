# SubSplit

Split premium subscriptions in Naira. This repository holds the **website only**:

- `index.html`: the customer app (Explore, My Subs, Wallet, Account)
- `admin/index.html`: the admin dashboard (only accounts listed as admins in the database can use it)
- `config.js`: the Supabase project URL and **publishable** key. Both are safe to be public.
- `api.js`: talks to Supabase

The database, security rules and payment functions run on Supabase. No secret keys belong in this repository.
