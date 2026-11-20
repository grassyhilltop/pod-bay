// PodBayKey: the operator key in JavaScript (same tokens and TOTP codes as key.py; see key.py for the design).
//   1. issueToken / verifyToken   capability token {operator, scope, laws_hash, exp}, HMAC-SHA256
//   2. totp / verifyTotp          RFC 6238 fallback
//   3. webauthnRegister / webauthnAssert   BROWSER ONLY, async: run the passkey ceremony on localhost and
//      return base64url fields for local_server.py, which verifies them with key.verify_webauthn_assertion.
//      Nothing in part 3 checks a signature in the page: the page is not trusted, the cell is.
// In the simulator the cell's secret lives in the page (a demo); in a real cell it never leaves the cell.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./hashes.js'));
  else root.PodBayKey = factory(root.PodBayHashes);
})(typeof self !== 'undefined' ? self : this, function (H) {
  'use strict';
  const OPERATOR = /^[A-Za-z0-9_.-]{1,32}$/, SCOPE = /^[a-z0-9:._-]{1,64}$/, HEX64 = /^[0-9a-f]{64}$/;
  const MAX_EXP = 2 ** 40, FIELDS = 'exp,laws_hash,operator,scope';
  const canon = (p) => JSON.stringify({ exp: p.exp, laws_hash: p.laws_hash, operator: p.operator, scope: p.scope })
    .replace(/[\u0080-\uffff]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));   // as Python's ensure_ascii
  const ascii = (b) => (b.every((x) => x < 128) ? String.fromCharCode.apply(null, b) : null);

  // ---- 1. capability token ----------------------------------------------------------------
  function issueToken(secret, operator, scope, lawsHash, ttlS = 600, now = Date.now() / 1000) {
    if (!OPERATOR.test(operator || '')) throw new Error('operator must be 1-32 of A-Z a-z 0-9 _ . -');
    if (!SCOPE.test(scope || '')) throw new Error('scope must be 1-64 of a-z 0-9 : . _ -');
    if (!HEX64.test(lawsHash || '')) throw new Error('laws_hash must be 64 lower-case hex digits');
    const exp = Math.floor(now) + Math.trunc(ttlS);
    const body = H.b64url(H.utf8(canon({ exp, laws_hash: lawsHash, operator, scope })));
    return body + '.' + H.b64url(H.hmac(H.sha256, secret, H.utf8(body)));
  }

  function verifyToken(token, secret, scope, lawsHash, now = Date.now() / 1000, maxTtlS = 900) {
    const no = (reason) => ({ valid: false, reason, operator: null });
    if (!token) return no('missing');
    const parts = typeof token === 'string' ? token.split('.') : [];
    if (parts.length !== 2) return no('malformed');
    const raw = H.unb64url(parts[0]), tag = H.unb64url(parts[1]);
    if (!raw || !tag) return no('malformed');
    if (!H.equal(tag, H.hmac(H.sha256, secret, H.utf8(parts[0])))) return no('bad_signature');
    const text = ascii(raw);
    let p;
    try { p = JSON.parse(text); } catch (e) { return no('malformed'); }
    if (!p || typeof p !== 'object' || Array.isArray(p) || Object.keys(p).sort().join(',') !== FIELDS) return no('malformed');
    if (!Number.isInteger(p.exp) || p.exp <= 0 || p.exp >= MAX_EXP || canon(p) !== text) return no('malformed');
    if (![p.operator, p.scope, p.laws_hash].every((v) => typeof v === 'string') || !OPERATOR.test(p.operator)) return no('malformed');
    if (now >= p.exp) return no('expired');
    if (p.exp - now > maxTtlS) return no('too_long');
    if (!H.equal(H.utf8(p.scope), H.utf8(String(scope)))) return no('wrong_scope');
    if (!H.equal(H.utf8(p.laws_hash), H.utf8(String(lawsHash)))) return no('laws_mismatch');
    return { valid: true, reason: 'ok', operator: p.operator };
  }

  const promptLine = (r) => (r && r.valid ? `OPERATOR KEY: valid (operator: ${r.operator})` : 'OPERATOR KEY: none');

  // ---- 2. TOTP fallback (RFC 6238) --------------------------------------------------------
  function b32secret(s) {
    const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567', out = [];
    let acc = 0, bits = 0;
    for (const ch of s.replace(/\s+/g, '').toUpperCase().replace(/=+$/, '')) {
      const v = A.indexOf(ch);
      if (v < 0) throw new Error('not base32');
      acc = (acc << 5 | v) & 0xffff; bits += 5;
      if (bits >= 8) { bits -= 8; out.push(acc >> bits & 255); }
    }
    return new Uint8Array(out);
  }
  function totp(secret, t = Date.now() / 1000, step = 30, digits = 6, algo = 'sha1', counter = null) {
    const c = counter === null ? Math.floor(t / step) : counter, msg = new Uint8Array(8);
    const hi = Math.floor(c / 0x100000000), lo = c >>> 0;
    [hi >>> 24, hi >>> 16, hi >>> 8, hi, lo >>> 24, lo >>> 16, lo >>> 8, lo].forEach((v, i) => { msg[i] = v & 255; });
    const h = H.hmac(algo === 'sha256' ? H.sha256 : H.sha1, secret, msg), o = h[h.length - 1] & 15;
    const v = ((h[o] & 0x7f) << 24 | h[o + 1] << 16 | h[o + 2] << 8 | h[o + 3]) >>> 0;
    return String(v % 10 ** digits).padStart(digits, '0');
  }
  function verifyTotp(code, secret, t = Date.now() / 1000, step = 30, digits = 6, algo = 'sha1', window = 1, lastCounter = -1) {
    if (typeof code !== 'string' || !new RegExp('^[0-9]{' + digits + '}$').test(code)) return { valid: false, counter: null };
    const c = Math.floor(t / step);
    for (let k = c - window; k <= c + window; k++) {
      if (k > lastCounter && H.equal(H.utf8(totp(secret, 0, step, digits, algo, k)), H.utf8(code))) return { valid: true, counter: k };
    }
    return { valid: false, counter: null };
  }

  // ---- 3. WebAuthn ceremony on localhost (browser only; verification happens in key.py) ----
  const bytesOf = (buf) => new Uint8Array(buf);
  async function webauthnRegister(operator, challengeB64) {
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: H.unb64url(challengeB64), rp: { id: 'localhost', name: 'PodBay cell' },
      user: { id: H.utf8(operator), name: operator, displayName: operator },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],          // ES256
      authenticatorSelection: { userVerification: 'required', residentKey: 'preferred' }, timeout: 60000 } });
    return { credential_id: H.b64url(bytesOf(cred.rawId)),
             public_key_der: H.b64url(bytesOf(cred.response.getPublicKey())) };   // store both in the cell
  }
  async function webauthnAssert(challengeB64, credentialIdB64) {
    const a = await navigator.credentials.get({ publicKey: {
      challenge: H.unb64url(challengeB64), rpId: 'localhost', userVerification: 'required', timeout: 60000,
      allowCredentials: [{ type: 'public-key', id: H.unb64url(credentialIdB64) }] } });
    return { client_data_json: H.b64url(bytesOf(a.response.clientDataJSON)),
             authenticator_data: H.b64url(bytesOf(a.response.authenticatorData)),
             signature: H.b64url(bytesOf(a.response.signature)) };          // POST to the cell
  }

  return { issueToken, verifyToken, promptLine, b32secret, totp, verifyTotp, webauthnRegister, webauthnAssert };
});
