// Web Push (RFC 8291 message encryption + RFC 8292 VAPID) on standard
// WebCrypto. No dependencies, so it runs in Supabase Edge Functions (Deno)
// and in the Node test suite unchanged.

const enc = new TextEncoder();

export const b64u = {
  encode(bytes) {
    let s = '';
    for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  },
  decode(str) {
    const s = atob(str.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (str.length % 4)) % 4));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  },
};

const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
};

// WebCrypto HKDF = Expand(Extract(salt, ikm), info, length).
async function hkdf(salt, ikm, info, length) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8));
}

// P-256 public key (65-byte uncompressed point) + optional private scalar → JWK.
function p256Jwk(publicRaw, privateD) {
  const jwk = { kty: 'EC', crv: 'P-256', x: b64u.encode(publicRaw.slice(1, 33)), y: b64u.encode(publicRaw.slice(33, 65)), ext: true };
  if (privateD) jwk.d = typeof privateD === 'string' ? privateD : b64u.encode(privateD);
  return jwk;
}

/**
 * Encrypt a push message for one subscription (aes128gcm content coding).
 * `testing` lets the tests inject the RFC 8291 example key pair and salt.
 */
export async function encryptPayload(subscription, payload, testing = {}) {
  const uaPublic = b64u.decode(subscription.keys.p256dh);
  const authSecret = b64u.decode(subscription.keys.auth);
  const plaintext = typeof payload === 'string' ? enc.encode(payload) : payload;

  let asPublic, asPrivateKey;
  if (testing.asPublic && testing.asPrivate) {
    asPublic = b64u.decode(testing.asPublic);
    asPrivateKey = await crypto.subtle.importKey('jwk', p256Jwk(asPublic, testing.asPrivate), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  } else {
    const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
    asPrivateKey = pair.privateKey;
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asPrivateKey, 256));

  const salt = testing.salt ? b64u.decode(testing.salt) : crypto.getRandomValues(new Uint8Array(16));
  const ikm = await hkdf(authSecret, ecdhSecret, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);

  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const record = concat(plaintext, new Uint8Array([2]));                // 0x02 = last (only) record
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, record));

  const rs = new Uint8Array(4); new DataView(rs.buffer).setUint32(0, 4096);
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, ciphertext);
}

/** VAPID Authorization header value: "vapid t=<JWT>, k=<public key>". */
export async function vapidAuthorization(endpoint, { publicKey, privateKey, subject }, nowSeconds = Math.floor(Date.now() / 1000)) {
  const header = b64u.encode(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64u.encode(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: nowSeconds + 12 * 3600, sub: subject })));
  const signingKey = await crypto.subtle.importKey('jwk', p256Jwk(b64u.decode(publicKey), privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, signingKey, enc.encode(`${header}.${claims}`));
  return `vapid t=${header}.${claims}.${b64u.encode(sig)}, k=${publicKey}`;
}

/** Send one push. Returns { ok, status, gone } — gone = subscription expired, delete it. */
export async function sendPush(subscription, message, vapid, fetchFn = fetch) {
  const body = await encryptPayload(subscription, JSON.stringify(message));
  const res = await fetchFn(subscription.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapidAuthorization(subscription.endpoint, vapid),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: '86400',
      Urgency: 'high',
    },
    body,
  });
  return { ok: res.ok, status: res.status, gone: res.status === 404 || res.status === 410 };
}

/** Make a new VAPID key pair (run once; see docs/push.md). */
export async function generateVapidKeys() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  return { publicKey: b64u.encode(raw), privateKey: jwk.d };
}
