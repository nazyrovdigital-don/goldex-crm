# Thumbtack integration

New Thumbtack lead → in the CRM within seconds → automatic reply inside Thumbtack
Messages (target < 60 s) → you get a 🔔 with the response time → you take over.

## What works when

| Capability | Needs | Status |
|---|---|---|
| Leads arrive in the CRM (customer, property, lead, project details, Thumbtack IDs) | Webhook set up in your Thumbtack account | Ready |
| Customer messages sync into the lead's conversation | Same webhook | Ready |
| Your replies from the Thumbtack app sync too (and count as takeover) | Same webhook | Ready |
| **Automatic reply inside Thumbtack Messages** | **Thumbtack partner API access** (OAuth, `messages` scope) | Ready, switches on when connected |
| Reply to the customer from the CRM | Partner API access | Ready, switches on when connected |
| Response-time KPIs, dashboard tiles, alerts, retries | — | Ready |

Thumbtack only lets approved partners post messages. Until approval, each new
Thumbtack lead still arrives instantly and you get an alert:
*"Auto-response: Thumbtack not connected — reply in the Thumbtack app now."*
Turning on Thumbtack's own auto-reply in your Pro settings covers the gap.

## Setup

### 1. Server secrets (Supabase → Edge Functions → Secrets)

```bash
supabase secrets set TT_WEBHOOK_USER=thumbtack TT_WEBHOOK_PASS=<long random password> \
  TT_WEBHOOK_TOKEN=<long random token> TT_DISPATCH_SECRET=<long random secret> \
  APP_URL=https://<where the CRM is hosted>
supabase functions deploy thumbtack-webhook --no-verify-jwt
supabase functions deploy thumbtack-dispatch --no-verify-jwt
supabase functions deploy thumbtack-oauth --no-verify-jwt
```

Generate each random value with `openssl rand -hex 24`.

### 2. Retry scheduler (SQL editor, once)

Enable **pg_cron** and **pg_net** under Database → Extensions, then:

```sql
select tt_setup_dispatch('https://<ref>.supabase.co/functions/v1/thumbtack-dispatch', '<TT_DISPATCH_SECRET>');
```

### 3. Point Thumbtack at the CRM

Create webhooks for **new leads (negotiations)** and **new messages** to:

```text
https://<ref>.supabase.co/functions/v1/thumbtack-webhook
```

Authentication: Basic, username `TT_WEBHOOK_USER`, password `TT_WEBHOOK_PASS`.
If Thumbtack's form only accepts a URL, use
`…/thumbtack-webhook?token=<TT_WEBHOOK_TOKEN>` instead.

### 4. Turn on the automatic reply (after Thumbtack approves partner access)

1. Request access at developers.thumbtack.com. You receive a Client ID and Client Secret.
2. `supabase secrets set TT_CLIENT_ID=… TT_CLIENT_SECRET=…`. Also set `TT_TOKEN_URL`,
   `TT_API_BASE` and `TT_SEND_PATH` if Thumbtack gives values different from the defaults
   (`https://auth.thumbtack.com/oauth2/token`, `https://pro-api.thumbtack.com`,
   `/api/v4/negotiations/{negotiationID}/messages`). **Confirm these with Thumbtack.**
3. Register the redirect URI with Thumbtack: `https://<ref>.supabase.co/functions/v1/thumbtack-oauth`.
4. CRM → Settings → Integrations → enter the Client ID (and authorize URL if different) → Save →
   **Connect Thumbtack** → approve in Thumbtack. Status changes to *connected*.

### 5. Production test (spec §18)

Use Thumbtack's staging environment if they give you one, or a real test request:

1. **New lead:** a lead appears with source Thumbtack and the full request.
2. **Auto-response:** the customer sees the message in Thumbtack, and the CRM shows ⚡ Response time.
3. **Conversation:** reply as the customer; the message appears on the lead.
4. **Duplicate:** Thumbtack retries are absorbed, so there's still one lead.
5. **Owner takeover:** click *Take over conversation*; no more automatic messages.

The first real payloads are stored raw (`webhook_events`, `thumbtack_leads.raw_payload`).
Check them once to confirm every field mapped. The normalizer accepts both Thumbtack's v4
and legacy formats.

## How it is built

```text
Thumbtack ─▶ thumbtack-webhook (Basic auth / token, 512 KB cap, rate limit)
               ├─ tt_ingest_lead    idempotent on Thumbtack lead id → customer, property, lead,
               │                    raw payload, metrics, conversation, outbox row
               └─ tt_ingest_message idempotent on message id → conversation, alerts, takeover
thumbtack-dispatch (immediately + every 15 s)
   tt_claim_outbox (SKIP LOCKED) → POST to Thumbtack → tt_complete_outbox
   failure → retry +15 s, +60 s, +3 min → 🚨 alert + urgent task
```

- **One auto-reply per lead, enforced by the database** (unique index), not only by code.
- **Tokens live in Supabase Vault (encrypted).** The CRM can't read them; only server functions can.
- **Response time** = first reply − the time Thumbtack says the customer submitted.
- Automatic replies don't count as you contacting the lead, so your 15/30/120-minute
  reminders keep running until you take over.
- Tables: `integrations`, `webhook_events`, `thumbtack_leads`, `thumbtack_messages`,
  `thumbtack_outbox`, `automation_events`, `lead_response_metrics` (migration 0009).
