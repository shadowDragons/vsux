# Windows waitlist

The website posts to `/api/waitlist`, a Vercel Node.js function. Only that function
holds the Supabase service role key. There is no database credential in the React
bundle. A failed or missing backend returns an error rather than a success message.

## Deployment

1. Create a dedicated Supabase project, e.g. `vsux-waitlist`, on your chosen plan.
2. Run `supabase/migrations/202611140001_windows_waitlist.sql` in its SQL Editor.
3. In the Vercel `web` project's environment settings, configure the variables in
   `.env.example` for Production. Use the project's URL and a server **secret**
   key (`sb_secret_…`); legacy **service_role** JWT keys also work. Never put a
   secret key into a `VITE_` variable.
   Generate `WAITLIST_RATE_SECRET` with `openssl rand -hex 32` and keep it private.
4. Deploy the website. If testing a preview, add its exact origin to
   `WAITLIST_ALLOWED_ORIGINS` (comma separated); do not allow arbitrary origins.
5. Submit a controlled test address, confirm one row appears in Table Editor,
   then submit the same address again and confirm there is still only one row.
   Confirm that anonymous clients cannot read the table or call the RPC.

Vite's standalone dev server does not run Vercel functions. Use Vercel's development
runtime with server environment variables when testing the full form locally.

## Storage and export

Supabase → your `vsux-waitlist` project → **Table Editor → windows_waitlist**.
Use the Table Editor's CSV export when preparing the Windows launch notification.
Rows contain email (normalized to lowercase), platform (`windows`), language
(`zh`/`en`), signup time, and consent-copy version. The first signup is kept when
an address is submitted again. No public read/write policies are installed.

`waitlist_rate_limits` stores short-lived HMAC hashes and attempt counts. Raw IP
addresses are not stored by this code. Expired counters are cleaned during later
signups; if traffic stops they remain until the next signup or admin cleanup.
Vercel/Supabase infrastructure may retain their own access logs under your plan.

The form records permission for a Windows launch notification only. It does not
send email, verify address ownership, or enroll people into general marketing.
Treat addresses as unverified before any future mailing; add verification and a
withdrawal/unsubscribe flow when implementing email delivery. To honor a deletion
request now, remove the address through the private Supabase dashboard.

## Abuse controls

The API validates the email, language, consent, JSON size/type, and allowed origin,
and rejects the hidden bot field. The database atomically caps attempts per hashed
IP per UTC hour at five across function instances. It relies on Vercel's protected
`x-vercel-forwarded-for` header. If hosting elsewhere, adapt the trusted IP source.
The cap is basic protection; add a server-verified CAPTCHA if automated signup
becomes an issue. No API response reveals whether an email was already registered.

## Verification

Run `npm test`, `npm audit`, and `npm run build` in `web/`. The API tests simulate
provider failures and assert key validation, privacy, and rate-limit behavior.
They do not replace the live database checks above.
