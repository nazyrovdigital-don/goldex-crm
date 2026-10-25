// Web Push encryption + VAPID, checked against the RFC 8291 worked example
// and by decrypting as a browser would.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encryptPayload, vapidAuthorization, generateVapidKeys, sendPush, b64u } from '../supabase/functions/push-send/webpush.js';

const RFC = {   // RFC 8291 §5
  plaintext: 'When I grow up, I want to be a watermelon',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  uaPrivate: 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  body: 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
};

// Browser-side decryption (what the phone does), used to prove round-trips.
async function decrypt(body, uaPublicB64, uaPrivateD, authB64) {
  const salt = body.slice(0, 16); const idlen = body[20]; const asPublic = body.slice(21, 21 + idlen); const ct = body.slice(21 + idlen);
  const uaPublic = b64u.decode(uaPublicB64);
  const jwk = { kty: 'EC', crv: 'P-256', x: b64u.encode(uaPublic.slice(1, 33)), y: b64u.encode(uaPublic.slice(33)), d: uaPrivateD };
  const priv = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const pub = await crypto.subtle.importKey('raw', asPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: pub }, priv, 256));
  const hk = async (s, ikm, info, n) => new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: s, info },
    await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']), n * 8));
  const te = new TextEncoder();
  const ikm = await hk(b64u.decode(authB64), ecdh, new Uint8Array([...te.encode('WebPush: info\0'), ...uaPublic, ...asPublic]), 32);
  const cek = await hk(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hk(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']);
  const pt = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, ct));
  assert.equal(pt.at(-1), 2, 'last-record delimiter');
  return new TextDecoder().decode(pt.slice(0, -1));
}

test('Encryption matches the RFC 8291 worked example byte for byte', async () => {
  const body = await encryptPayload({ keys: { p256dh: RFC.uaPublic, auth: RFC.auth } }, RFC.plaintext,
    { asPublic: RFC.asPublic, asPrivate: RFC.asPrivate, salt: RFC.salt });
  assert.equal(b64u.encode(body), RFC.body);
});

test('Random-key messages decrypt correctly on the receiving side', async () => {
  const msg = JSON.stringify({ title: '🔔 New lead: Maria Lopez', body: 'Cabinet Installation · Carlsbad', url: './#/lead/123' });
  const body = await encryptPayload({ keys: { p256dh: RFC.uaPublic, auth: RFC.auth } }, msg);
  assert.equal(await decrypt(body, RFC.uaPublic, RFC.uaPrivate, RFC.auth), msg);
});

test('VAPID header carries a valid ES256 signature for the push service origin', async () => {
  const keys = await generateVapidKeys();
  const h = await vapidAuthorization('https://web.push.apple.com/QGuQyavXutnMH', { ...keys, subject: 'mailto:olim@goldexconst.com' }, 1_800_000_000);
  const [, t, k] = h.match(/^vapid t=([^,]+), k=(.+)$/);
  assert.equal(k, keys.publicKey);
  const [hd, cl, sig] = t.split('.');
  const claims = JSON.parse(new TextDecoder().decode(b64u.decode(cl)));
  assert.deepEqual(claims, { aud: 'https://web.push.apple.com', exp: 1_800_000_000 + 43200, sub: 'mailto:olim@goldexconst.com' });
  const pub = await crypto.subtle.importKey('raw', b64u.decode(keys.publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, b64u.decode(sig), new TextEncoder().encode(`${hd}.${cl}`)));
});

test('sendPush posts an encrypted body and flags expired subscriptions', async () => {
  const keys = await generateVapidKeys();
  let req;
  const fake = async (url, init) => { req = { url, init }; return new Response(null, { status: 410 }); };
  const r = await sendPush({ endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: { p256dh: RFC.uaPublic, auth: RFC.auth } },
    { title: 'Test' }, { ...keys, subject: 'mailto:x@example.com' }, fake);
  assert.deepEqual(r, { ok: false, status: 410, gone: true });
  assert.equal(req.init.headers['Content-Encoding'], 'aes128gcm');
  assert.match(req.init.headers.Authorization, /^vapid t=.+, k=/);
  assert.equal(await decrypt(req.init.body, RFC.uaPublic, RFC.uaPrivate, RFC.auth), '{"title":"Test"}');
});

test('Database: devices register per user, test alerts are created, and push never blocks a notification', async () => {
  const { createDb, asUser, val, one, OWNER } = await import('./helpers.js');
  const db = await createDb();
  const sid = await val(db, `select push_subscribe('https://web.push.apple.com/abc', 'p256', 'auth', 'iPhone')`);
  assert.ok(sid);
  await db.query(`select push_subscribe('https://web.push.apple.com/abc', 'p256b', 'auth2', 'iPhone')`);
  assert.equal(await val(db, `select count(*)::int from push_subscriptions`), 1, 're-enabling the same phone does not duplicate it');
  await assert.rejects(db.query(`select push_subscribe('http://evil.example/x', 'a', 'b')`), /Invalid push endpoint/);
  await assert.rejects(db.query(`insert into push_subscriptions (endpoint, p256dh, auth) values ('https://x', 'a', 'b')`), /permission denied/);
  // No push URL configured (like local tests) → notification still saved.
  await db.query(`select push_test()`);
  assert.ok(await one(db, `select 1 from notifications where kind = 'test' and user_id = $1`, [OWNER]));
  await asUser(db, null);
  assert.equal(await val(db, `select count(*)::int from push_subscriptions`), 0, 'anon sees no devices');
});
