# GOLDEX CRM V2

Construction operating system for GOLDEX Construction LLC.
Lead → estimate → proposal → **automatic project** → deposit → job costing → payment → review.

Architecture, data model and phase status: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Website hookup: [docs/website-form.md](docs/website-form.md).
Thumbtack integration: [docs/thumbtack.md](docs/thumbtack.md).

## Try it now (demo mode, no account needed)

```bash
npm install && npm run dev
```

Open <http://localhost:5173/app/>. With `app/js/config.js` empty, the app runs a real
Postgres database **inside your browser** (PGlite), using the same migrations plus
your V1 sample data. Demo data stays in that browser; it isn't for real work.

## Go live on Supabase (about 30 minutes)

1. Create a project at supabase.com (region: West US). Pro plan ($25/mo) for daily backups.
2. **SQL Editor** → run each file in `supabase/migrations/` in order (0001 → 0009).
   Do **not** run `supabase/dev/auth_shim.sql`; that's only for local testing.
3. **Authentication → Sign In / Providers**: turn **off** "Allow new users to sign up".
   **Authentication → Users → Add user** → create your account (email + password).
   The first account automatically becomes the active owner.
4. **Project Settings → API**: copy the Project URL and the `anon` / publishable key into
   `app/js/config.js`. Never put the `service_role` key in the app.
5. Host the repo on any static host (GitHub Pages works). Open `/app/`, sign in.
6. **Settings → Import / export → Import from CRM V1** to bring over your old data.
7. Website leads: deploy the function, then follow `docs/website-form.md`.
   ```bash
   supabase functions deploy lead-intake --no-verify-jwt
   supabase secrets set RESEND_API_KEY=… FROM_EMAIL="GOLDEX <crm@goldexconst.com>" OWNER_EMAIL=olim@goldexconst.com
   ```
8. Check **Settings → Pricing & labor**: target margin, margin bands, deposit cap, and your
   loaded labor rate (what you'd pay someone to replace you in the field).

pg_cron (step 2, migration 0007) runs delayed automations every 5 minutes. If it
wasn't available, enable it under **Database → Extensions** and re-run the last block of 0007.

## Tests

```bash
npm test
```

Spins up Postgres (PGlite), applies every migration, and runs the spec §84 acceptance
scenarios: website lead, estimate costing, proposal, automatic project, job costing,
payment controls, lost reasons, numbering, audit, security (RLS) and V1 import, plus the
Thumbtack tests 1–7 (new lead, auto-response, response time, conversation, duplicates,
API failure + retries, owner takeover) against a simulated Thumbtack API.

## Layout

```text
app/                    browser app (index.html, css/, js/app.js, js/db.js, js/pages/*)
supabase/migrations/    schema, automation engine, rules, views, security, V1 import
supabase/functions/     edge functions: lead-intake (website), thumbtack-webhook / -dispatch / -oauth, _shared
supabase/dev/           local-only Supabase auth shim for tests/demo
tests/                  acceptance tests
```
