// ingest/auth.js
// Two doors, two keys:
//   agents   → POST /v1/ingest with "Authorization: Bearer <server token>"
//   humans   → the portal and its read API, behind HTTP Basic auth
// Basic auth is the stopgap until Clerk accounts exist. The browser asks once
// and resends the login on every same-origin request, so the portal pages
// need no changes.

const crypto = require('crypto');

// Compare secrets without leaking their length or content through timing.
function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function bearerToken(req) {
  const h = req.headers.authorization || '';
  const m = /^Bearer\s+(\S+)$/i.exec(h);
  return m ? m[1] : '';
}

function portalAuth({ user, password }) {
  return function requirePortalLogin(req, res, next) {
    const h = req.headers.authorization || '';
    const m = /^Basic\s+([A-Za-z0-9+/=]+)$/i.exec(h);
    if (m) {
      const decoded = Buffer.from(m[1], 'base64').toString('utf8');
      const i = decoded.indexOf(':');
      if (i > 0) {
        const okUser = safeEqual(decoded.slice(0, i), user);
        const okPass = safeEqual(decoded.slice(i + 1), password);
        if (okUser && okPass) return next();
      }
    }
    res.set('WWW-Authenticate', 'Basic realm="Sentinel", charset="UTF-8"');
    return res.status(401).json({ ok: false, error: { code: 'login_required' } });
  };
}

module.exports = { safeEqual, bearerToken, portalAuth };
