# GOLDEX CRM V2 — Architecture & developer confirmation (spec §4)

```text
Frontend:          Static HTML + ES modules (app/), no build step. Hostable on GitHub Pages / Netlify / Vercel.
Backend:           Supabase — PostgreSQL 17, PostgREST API, Postgres functions for all workflows.
Database:          Supabase Postgres. Schema in supabase/migrations (9 files, applied in order).
Authentication:    Supabase Auth (email + password, password reset). First account = owner; later sign-ups
                   are "pending" with no access until the owner activates them. Disable public sign-ups.
File storage:      Supabase Storage — P1 (receipts, photos, documents). Columns already exist (receipt_file_id, contract_document_id).
Email service:     Resend via the lead-intake Edge Function (optional; owner alert + customer confirmation).
Thumbtack:         Webhooks → thumbtack-webhook; auto-reply via Thumbtack Messages API (partner OAuth,
                   tokens in Supabase Vault); retries via pg_cron + pg_net. See docs/thumbtack.md.
SMS service:       Not in V2 P0. Communication log records calls/texts manually (P1: Twilio).
Hosting:           Supabase (DB, API, functions). Frontend on any static host over HTTPS.
Backup:            Supabase daily backups (Pro: 7-day retention; PITR add-on). Plus Settings → Export full JSON / CSV.
API:               PostgREST + RPC functions protected by row-level security. Engine internals are not exposed.
CRM ↔ Website:     Website form → Edge Function lead-intake (service role, honeypot, validation)
                   → intake_website_lead() → customer + property + lead + task + notification + SLA reminders.
```

## Why this shape

- **The database owns the business rules.** Totals, margins, deposit caps, payment
  validation, numbering, audit history and automations live in Postgres functions
  and triggers. The UI cannot get them wrong, and neither can a future mobile app,
  an import, or someone editing a row in the Supabase dashboard.
- **Automations are rows, not code** (spec §70). `automation_rules` holds
  trigger + conditions + ordered actions + optional delay. Database triggers emit
  events (`lead.created`, `proposal.approved`, `deposit.paid`, …). Immediate rules run
  in the same transaction as the change, so a proposal approval creates the
  project, invoice, checklist and tasks completely or not at all. Delayed rules go
  to `scheduled_actions`, which pg_cron runs every 5 minutes, and re-check their
  conditions first ("still not approved after 5 days").
- **Relationships are IDs only** (spec §63). Names, numbers and array positions are display values.
- **Numbers** (LEAD-, EST-, PROP-, PRJ-, INV-…) come from Postgres sequences: never
  duplicated, even after deletes or concurrent use. Gaps can appear after a crash
  or rollback (Postgres pre-allocates 32 values); that is expected.
- **Nothing financial is hard-deleted.** Payments are voided, invoices voided,
  everything else archived (`archived_at`). `audit_log` records every change with
  old → new values and the user.

## Data model (main tables)

| Area | Tables |
|---|---|
| People | `users` (role, status, labor & burden rate) |
| Sales | `customers`, `properties`, `leads`, `communications` |
| Estimating | `pricebook_items`, `estimates`, `estimate_items` |
| Contract | `proposals`, `proposal_items` |
| Operations | `projects`, `project_checklist_items`, `tasks`, `calendar_events`, `materials` |
| Money | `invoices`, `payments`, `expenses`, `time_entries` |
| System | `settings`, `automation_rules`, `scheduled_actions`, `automation_log`, `notifications`, `audit_log` |

Views: `v_leads` (next action, SLA), `v_project_financials` → `v_project_profit` →
`v_project_outlook` (true job cost, projected and expected profit), `v_invoices` (overdue, aging).
RPC: `dashboard_summary`, `global_search`, `create_estimate_from_lead`,
`create_proposal_from_estimate`, `send_proposal`, `approve_proposal`, `decline_proposal`,
`record_payment`, `void_payment`, `mark_lead_lost`, `run_maintenance`, `import_v1`.

## True gross profit (spec §21)

```text
contract value + approved change orders
− materials − direct labor (hours × loaded rate, owner included) − subcontractors
− delivery − disposal − equipment − other direct costs
= gross profit            gross profit ÷ revenue = gross margin
```

Open jobs are managed on **projected** profit: the larger of the budget or the actual
cost extrapolated from % complete. Completed jobs use actual profit.

## Phase status

| Phase | Status |
|---|---|
| 1 Database + backend + auth | ✅ schema, RLS, audit, numbering, backups via Supabase |
| 2 Customer + lead + pipeline | ✅ properties, scoring A–D, kanban, SLA, lost reasons, Customer 360, search |
| 3 Estimate + price book + job costing | ✅ full unit costs, live margin vs. configurable thresholds, project job cost |
| 4 Proposal → approval → project | ✅ full lifecycle, locked contract, automatic project/deposit/tasks |
| 5–8 | Partly: tasks, calendar, materials, invoices/payments/AR, time, expenses, checklists exist. **Not yet:** change orders, daily logs, QC records, purchase orders, photos/documents |
| 9 Automation engine | ✅ engine + 20 rules (configurable UI for editing rule JSON is P1) |
| 10 CEO dashboard | ✅ core KPIs, owner independence, AR aging. Full report pack (§75) not yet |
| 11 Mobile field mode | Responsive layout only; dedicated field mode not yet |

## Known limitations

- Business-hours awareness for lead SLAs is not implemented (reminders fire 24/7).
- Customer-facing proposal e-sign link is not built; approval is recorded by the owner (typed signature).
- Single-role access today: all active users see everything. Crew scoping goes in the RLS policies in `0007_security.sql`.
