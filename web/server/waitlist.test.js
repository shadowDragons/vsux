import test from 'node:test';
import assert from 'node:assert/strict';
import { createWaitlistHandler } from './waitlist.js';

const env = {
  SUPABASE_URL: 'https://test.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'test-server-key',
  WAITLIST_RATE_SECRET: 'test-rate-secret-with-at-least-32-characters',
};
const headers = { origin: 'https://vsux.sphrag.com', 'content-type': 'application/json', 'x-vercel-forwarded-for': '192.0.2.1' };
const signup = { email: ' Test@Example.com ', language: 'en', consent: true, website: '' };

async function run({ body = signup, method = 'POST', requestHeaders = headers, config = env, fetcher = async () => Response.json('saved'), time = 0 } = {}) {
  const result = { headers: {} };
  const res = {
    setHeader(name, value) { result.headers[name] = value; },
    status(status) { result.status = status; return this; },
    json(body) { result.body = body; return this; },
  };
  await createWaitlistHandler({ env: config, fetcher, now: () => time })({ method, headers: requestHeaders, body }, res);
  return result;
}

test('signup normalizes email and sends only intended fields; keeps secrets out of response', async () => {
  let payload;
  const result = await run({ fetcher: async (url, options) => {
    assert.equal(url, 'https://test.supabase.co/rest/v1/rpc/join_windows_waitlist');
    assert.equal(options.headers.apikey, env.SUPABASE_SERVICE_ROLE_KEY);
    payload = JSON.parse(options.body);
    return Response.json('saved');
  } });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { ok: true });
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.deepEqual(Object.keys(payload).sort(), ['p_email', 'p_language', 'p_rate_key']);
  assert.equal(payload.p_email, 'test@example.com');
  assert.equal(payload.p_language, 'en');
  assert.match(payload.p_rate_key, /^[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(payload).includes('192.0.2.1'));
});

test('rate keys are stable within one hour and rotate between hours and client IPs', async () => {
  const keys = [];
  const fetcher = async (_url, options) => { keys.push(JSON.parse(options.body).p_rate_key); return Response.json('saved'); };
  await run({ fetcher });
  await run({ fetcher, time: 1000 });
  await run({ fetcher, time: 3600000 });
  await run({ fetcher, requestHeaders: { ...headers, 'x-vercel-forwarded-for': '192.0.2.2' } });
  assert.equal(keys[0], keys[1]);
  assert.notEqual(keys[0], keys[2]);
  assert.notEqual(keys[0], keys[3]);
});

test('modern Supabase secret uses the apikey header without an invalid Bearer token', async () => {
  const key = 'sb_secret_test_only';
  const result = await run({ config: { ...env, SUPABASE_SERVICE_ROLE_KEY: key }, fetcher: async (_url, options) => {
    assert.equal(options.headers.apikey, key);
    assert.equal(options.headers.Authorization, undefined);
    return Response.json('saved');
  } });
  assert.equal(result.status, 200);
});

test('rejects invalid input and bot traps before contacting storage', async () => {
  const fetcher = () => assert.fail('invalid request must not contact storage');
  for (const body of [null, [], '{broken', { ...signup, email: 'a@b' }, { ...signup, email: 'a b@example.com' }, { ...signup, email: 'a'.repeat(65) + '@example.com' }, { ...signup, consent: 'true' }, { ...signup, language: 'other' }, { ...signup, website: 'spam' }]) {
    assert.equal((await run({ body, fetcher })).status, 400);
  }
});

test('rejects wrong method, cross-site, oversized, and non-JSON requests', async () => {
  const fetcher = () => assert.fail('invalid request must not contact storage');
  assert.equal((await run({ method: 'GET', fetcher })).status, 405);
  assert.equal((await run({ requestHeaders: { ...headers, origin: 'https://evil.example' }, fetcher })).status, 403);
  assert.equal((await run({ requestHeaders: { ...headers, 'content-type': 'text/plain' }, fetcher })).status, 415);
  assert.equal((await run({ body: { ...signup, extra: 'a'.repeat(2100) }, fetcher })).status, 413);
});

test('fails closed when configuration or trusted Vercel IP is missing', async () => {
  const fetcher = () => assert.fail('must not contact storage');
  assert.equal((await run({ config: {}, fetcher })).status, 503);
  assert.equal((await run({ config: { ...env, WAITLIST_RATE_SECRET: 'short' }, fetcher })).status, 503);
  assert.equal((await run({ requestHeaders: { ...headers, 'x-vercel-forwarded-for': undefined, 'x-forwarded-for': 'spoofed' }, fetcher })).status, 503);
});

test('only explicit database success produces success; errors never expose provider details', async () => {
  for (const fetcher of [
    async () => new Response('secret provider detail', { status: 500 }),
    async () => Response.json('unexpected'),
    async () => { throw new Error('private connection details'); },
    async () => new Response('not json'),
  ]) {
    const result = await run({ fetcher });
    assert.equal(result.status, 503);
    assert.deepEqual(result.body, { error: 'unavailable' });
  }
});

test('durable database rate limit is returned with a retry interval', async () => {
  const result = await run({ fetcher: async () => Response.json('rate_limited') });
  assert.equal(result.status, 429);
  assert.equal(result.headers['Retry-After'], '3600');
  assert.deepEqual(result.body, { error: 'rate_limited' });
});
