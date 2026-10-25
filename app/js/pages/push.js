// Settings → Notifications: turn on push alerts for this phone/computer.
import { db, register, refresh } from '../app.js';
import { PUSH_PUBLIC_KEY } from '../config.js';
import { DEMO } from '../db.js';
import { html, toast, badge, ago } from '../ui.js';

const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent);
const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

const keyBytes = (b64) => {
  const s = atob(b64.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (b64.length % 4)) % 4));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
};

async function currentSubscription() {
  if (!supported) return null;
  const reg = await navigator.serviceWorker.getRegistration();
  return reg ? reg.pushManager.getSubscription() : null;
}

export async function notificationsTab() {
  const [sub, devices] = await Promise.all([currentSubscription(), db.list('push_subscriptions', { order: 'created_at desc' }).catch(() => [])]);
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  const thisOn = !!sub && devices.some((d) => d.endpoint === sub.endpoint);
  let help = '';
  if (DEMO) help = 'Not available in demo mode.';
  else if (isIOS && !standalone) help = 'On iPhone, notifications only work from the home-screen app: tap Share → Add to Home Screen, open GOLDEX from the icon, then come back here.';
  else if (!supported) help = 'This browser does not support push notifications. On iPhone use the home-screen app (iOS 16.4+).';
  else if (perm === 'denied') help = isIOS ? 'Notifications are blocked. iPhone Settings → Notifications → GOLDEX → Allow Notifications.' : 'Notifications are blocked for this site in your browser settings.';
  return html`<div class="grid-2">
    <div class="card"><div class="card-title">This device ${thisOn ? badge('ON', 'green') : badge('OFF', 'muted')}</div>
      <p class="small muted" style="margin-bottom:12px">Get a lock-screen alert within seconds for new leads, Thumbtack messages, payments and escalations — even when the CRM is closed.</p>
      ${help ? html`<div class="toast toast-error" style="max-width:none;margin-bottom:12px">${help}</div>` : ''}
      <div class="pill-row">
        ${thisOn ? html`<button class="btn btn-gold" data-act="pushTest">Send test notification</button><button class="btn btn-ghost" data-act="pushOff">Turn off on this device</button>`
          : html`<button class="btn btn-gold" data-act="pushOn" ${help && perm !== 'default' ? 'disabled' : ''}>🔔 Turn on notifications</button>`}
      </div></div>
    <div class="card"><div class="card-title">Your devices (${devices.length})</div>
      ${devices.length ? devices.map((d) => html`<div class="list-item"><div class="list-main"><div class="list-name">${/iPhone/.test(d.user_agent) ? '📱 iPhone' : /iPad/.test(d.user_agent) ? '📱 iPad' : /Android/.test(d.user_agent) ? '📱 Android' : /Mac/.test(d.user_agent) ? '💻 Mac' : '💻 Computer'}${sub && d.endpoint === sub.endpoint ? ' (this one)' : ''}</div>
        <div class="list-sub">added ${ago(d.created_at)}${d.last_used_at ? ' · last alert ' + ago(d.last_used_at) : ''}</div></div></div>`)
        : html`<div class="muted small">No devices yet.</div>`}</div></div>`;
}

register({
  pushOn: async () => {
    if (!supported) throw new Error('Push is not supported here.');
    const perm = await Notification.requestPermission();
    if (perm !== 'granted') throw new Error('Notifications were not allowed.');
    const reg = await navigator.serviceWorker.ready;
    const sub = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(PUSH_PUBLIC_KEY) });
    const j = sub.toJSON();
    await db.rpc('push_subscribe', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_user_agent: navigator.userAgent });
    toast('Notifications on for this device'); refresh();
  },
  pushTest: async () => { await db.rpc('push_test'); toast('Test sent — it should arrive in a few seconds'); },
  pushOff: async () => {
    const sub = await currentSubscription();
    if (sub) { await db.removeWhere('push_subscriptions', { eq: { endpoint: sub.endpoint } }); await sub.unsubscribe(); }
    toast('Notifications off for this device'); refresh();
  },
});
