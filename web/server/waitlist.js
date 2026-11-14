import { createHmac } from 'node:crypto';

const EMAIL = /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$/i;

export function createWaitlistHandler({ env = process.env, fetcher = fetch, now = Date.now } = {}) {
  return async function waitlist(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, data) => res.status(status).json(data);
    if (req.method !== 'POST') {
      res.setHeader('Allow', 'POST');
      return send(405, { error: 'method_not_allowed' });
    }
    const allowedOrigins = (env.WAITLIST_ALLOWED_ORIGINS || 'https://vsux.sphrag.com').split(',').map(value => value.trim());
    if (!allowedOrigins.includes(req.headers.origin)) return send(403, { error: 'forbidden' });
    if (req.headers['content-type']?.split(';')[0].trim() !== 'application/json') return send(415, { error: 'json_required' });
    let body;
    try {
      if (Number(req.headers['content-length']) > 2048) return send(413, { error: 'payload_too_large' });
      if (Buffer.byteLength(typeof req.body === 'string' ? req.body : JSON.stringify(req.body ?? null)) > 2048) return send(413, { error: 'payload_too_large' });
      body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    } catch {
      return send(400, { error: 'invalid_input' });
    }
    if (!body || Array.isArray(body) || typeof body !== 'object') return send(400, { error: 'invalid_input' });
    // Bot traps never create a row or disclose whether an address is registered.
    if (body.website) return send(400, { error: 'invalid_input' });
    const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
    if (email.length > 254 || email.split('@')[0].length > 64 || !EMAIL.test(email) || !['zh', 'en'].includes(body.language) || body.consent !== true) {
      return send(400, { error: 'invalid_input' });
    }
    const { SUPABASE_URL: url, SUPABASE_SERVICE_ROLE_KEY: key, WAITLIST_RATE_SECRET: rateSecret } = env;
    if (!url || !key || !rateSecret || rateSecret.length < 32) return send(503, { error: 'unavailable' });
    // Vercel overwrites this header with the client IP. Do not trust a client-supplied x-forwarded-for.
    const ip = req.headers['x-vercel-forwarded-for']?.split(',')[0].trim();
    if (!ip) return send(503, { error: 'unavailable' });
    const hour = Math.floor(now() / 3600000);
    const rateKey = createHmac('sha256', rateSecret).update(`${hour}:${ip}`).digest('hex');
    try {
      const response = await fetcher(`${url.replace(/\/$/, '')}/rest/v1/rpc/join_windows_waitlist`, {
        method: 'POST',
        headers: { apikey: key, ...(key.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${key}` }), 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_email: email, p_language: body.language, p_rate_key: rateKey }),
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) return send(503, { error: 'unavailable' });
      const result = await response.json();
      if (result === 'rate_limited') {
        res.setHeader('Retry-After', '3600');
        return send(429, { error: 'rate_limited' });
      }
      if (result !== 'saved') return send(503, { error: 'unavailable' });
      return send(200, { ok: true });
    } catch {
      // Never log request bodies, emails, provider responses, or credentials.
      return send(503, { error: 'unavailable' });
    }
  };
}
