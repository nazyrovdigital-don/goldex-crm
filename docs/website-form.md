# Connecting goldexconst.com to the CRM

The live form (`#quoteForm`) already sends every submission to two places:

1. **Formspree**: emails you, and decides the "Thank you" message.
2. **Google Apps Script** (`LEADS_URL`): fire-and-forget copy, likely a Google Sheet.

The CRM is a third fire-and-forget copy, added the same way. Nothing else on the
site changes. Field names (`name`, `phone`, `email`, `type`, `address`, `details`)
are accepted as-is by the `lead-intake` function.

## 1. Deploy the intake function (once)

```bash
supabase functions deploy lead-intake --no-verify-jwt
```

`--no-verify-jwt` lets the public website call it. It's still protected: it only accepts
requests from goldexconst.com, validates every field, drops bots (honeypot), and the
database key it uses never leaves Supabase.

Optional email alerts (owner + customer confirmation):

```bash
supabase secrets set RESEND_API_KEY=… FROM_EMAIL="GOLDEX <crm@goldexconst.com>" OWNER_EMAIL=olim@goldexconst.com
```

## 2. Add two lines to the site's script

In `index.html`, next to the existing `LEADS_URL` line:

```js
const CRM_URL = 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/lead-intake';
```

and next to the existing Google Script `fetch(...)` inside the submit handler:

```js
try { fetch(CRM_URL, { method: 'POST', mode: 'no-cors', body: new URLSearchParams(new FormData(form)) }).catch(() => {}); } catch (err) {}
```

## 3. Optional: ad-campaign tracking

To see which Google/Facebook campaign produced each lead, add hidden inputs to the form:

```html
<input type="hidden" name="utm_source"><input type="hidden" name="utm_medium">
<input type="hidden" name="utm_campaign"><input type="hidden" name="source_page">
<input name="company_website" tabindex="-1" autocomplete="off" style="position:absolute;left:-9999px" aria-hidden="true">
```

and fill them on page load:

```js
const q = new URLSearchParams(location.search);
['utm_source', 'utm_medium', 'utm_campaign'].forEach((k) => {
  if (q.get(k)) sessionStorage.setItem(k, q.get(k));
  form.elements[k].value = sessionStorage.getItem(k) || '';
});
form.elements.source_page.value = location.pathname;
```

(`company_website` is a spam trap: people never see it, bots fill it in, and the CRM ignores those.)

## 4. Test

Submit the form once on the live site. Within seconds the CRM shows a NEW LEAD with
source **Website**, an **Urgent** "Contact new lead" task and a 🔔 notification.
Reminders follow at 15 min, 30 min and 2 hr until you log contact or move the lead.
