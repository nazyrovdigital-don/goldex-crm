// "Connect Thumbtack" OAuth callback.
//
// Flow: CRM Settings → Connect Thumbtack → (CRM gets a one-time state from
// tt_oauth_begin) → Thumbtack login/consent → Thumbtack redirects here with
// ?code&state → we check the state, exchange the code for tokens using the
// client secret (server-side only) and store the tokens in Supabase Vault.
//
// Register this redirect URI with Thumbtack:
//   https://<ref>.supabase.co/functions/v1/thumbtack-oauth
// Secrets: TT_CLIENT_ID, TT_CLIENT_SECRET, TT_TOKEN_URL, APP_URL (where the CRM is hosted).
// Deploy with --no-verify-jwt.
import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const app = (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '');
  const back = (status: string) => Response.redirect(`${app}/app/#/settings?thumbtack=${encodeURIComponent(status)}`, 302);
  if (url.searchParams.get('error')) return back('denied');
  const code = url.searchParams.get('code'); const state = url.searchParams.get('state');
  if (!code || !state) return back('missing_code');

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: ok } = await sb.rpc('tt_oauth_consume_state', { p_state: state });
  if (!ok) return back('invalid_state');

  const res = await fetch(Deno.env.get('TT_TOKEN_URL') ?? 'https://auth.thumbtack.com/oauth2/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded',
               Authorization: 'Basic ' + btoa(`${Deno.env.get('TT_CLIENT_ID')}:${Deno.env.get('TT_CLIENT_SECRET')}`) },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: `${url.origin}${url.pathname}` }).toString(),
  });
  if (!res.ok) {
    console.error('token exchange failed', res.status, await res.text());
    await sb.rpc('tt_set_integration_error', { p_error: `Token exchange failed (${res.status})`, p_status: 'error' });
    return back('token_failed');
  }
  const t = await res.json();
  const { error } = await sb.rpc('tt_store_tokens', { p_access: t.access_token, p_refresh: t.refresh_token ?? null,
    p_expires_in: t.expires_in ?? 3600, p_account_id: t.business_id ?? t.user_id ?? null, p_scopes: t.scope ?? null });
  if (error) { console.error(error); return back('store_failed'); }
  return back('connected');
});
