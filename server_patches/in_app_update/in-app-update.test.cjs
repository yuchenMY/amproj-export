'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const express = require('express');
const { capabilityStore, matchesIdentity, prepareUpdateIpa, registerAppUpdates, recoverSigningJobs, ipaMetadata } = require('./in-app-update');
const { integrate } = require('./integrate.cjs');
const hashToken = (text) => crypto.createHash('sha256').update(text).digest('hex');
const identity = { deviceId: 1, channel: 'production', bundleId: 'com.ayakameow.am', teamId: 'TEAM01', release: 176 };
const store = capabilityStore('fixture-only-key');

function fixtureIpa(destination, info) {
  const name = Buffer.from('Payload/Test.app/Info.plist');
  const data = Buffer.from(require('plist').build(info));
  let crc = 0xffffffff;
  for (const byte of data) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  crc = (crc ^ 0xffffffff) >>> 0;
  const header = Buffer.alloc(30); header.writeUInt32LE(0x04034b50); header.writeUInt16LE(20, 4); header.writeUInt32LE(crc, 14); header.writeUInt32LE(data.length, 18); header.writeUInt32LE(data.length, 22); header.writeUInt16LE(name.length, 26);
  const central = Buffer.alloc(46); central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt32LE(crc, 16); central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28);
  const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(central.length + name.length, 12); end.writeUInt32LE(header.length + name.length + data.length, 16);
  fs.writeFileSync(destination, Buffer.concat([header, name, data, central, name, end]));
}

test('capability rejects forgery, expiration and identity changes', () => {
  const token = store.issue(identity, 1000000);
  assert.equal(store.verify(token, 1000001).deviceId, 1);
  assert.equal(store.verify(token.slice(0, -1) + (token.endsWith('A') ? 'B' : 'A'), 1000001), null);
  const changed = Buffer.from(JSON.stringify({ ...identity, deviceId: 2 })).toString('base64url');
  assert.equal(store.verify(changed + '.' + token.split('.')[1], 1000001), null);
  assert.equal(store.verify(token, 1000000 + 3 * 365 * 86400000), null);
  assert.equal(store.verify(token, 1), null);
  for (const [key, value] of Object.entries({ deviceId: 2, channel: 'beta', bundleId: 'other.app', teamId: 'TEAM02' })) assert.equal(matchesIdentity(identity, { ...identity, [key]: value }), false);
});

async function harness(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'meow-update-'));
  const ipa = path.join(dir, 'source.ipa');
  fixtureIpa(ipa, { CFBundleIdentifier: identity.bundleId, AMProjReleaseCode: 177, AMProjReleaseChannel: 'stable' });
  const state = { device: { id: 1, udid: 'FIXTURE', allowed: 1, beta_access: 0 }, application: { id: 7, ipa_path: ipa, channel: 'production', bundle_id: identity.bundleId, is_default: 1 },
    profile: { id: 3, team_id: identity.teamId, bundle_id: '*' }, certificate: { id: 4 }, jobs: [], enqueued: [], audit: [], qualified: true };
  let serial = Promise.resolve();
  const db = {
    async transaction(fn) { const previous = serial; let done; serial = new Promise((r) => { done = r; }); await previous; try { return await fn(db); } finally { done(); } },
    prepare(sql) {
      return {
        async get(...args) {
          if (sql.startsWith('SELECT * FROM udid_requests')) return args[0] === hashToken('a'.repeat(48)) ? { status: 'completed', udid: 'FIXTURE' } : null;
          if (sql.includes('FROM devices')) return (sql.includes('WHERE udid') ? args[0] === state.device.udid : args[0] === state.device.id) ? { ...state.device } : null;
          if (sql.includes('FROM apps')) return args[0] === state.application.channel ? { ...state.application } : null;
          if (sql.includes('WHERE public_token_hash')) return state.jobs.find((job) => job.hash === args[0]);
          if (sql.includes('FROM sign_jobs') && sql.includes("status IN ('queued', 'running')")) return state.jobs.find((job) => ['queued','running'].includes(job.status) && job.device_id === args[0]);
          throw new Error('Unexpected query: ' + sql);
        },
        async run(...args) {
          assert.ok(sql.startsWith('INSERT INTO sign_jobs'));
          const id = state.jobs.length + 1; state.jobs.push({ id, device_id: args[0], app_id: args[1], certificate_id: args[2], profile_id: args[3], hash: args[4], status: 'queued' });
          return { lastInsertRowid: id };
        }
      };
    }
  };
  const app = express(); app.use(express.json());
  registerAppUpdates(app, { db, config: { encryptionKey: 'fixture-only-key' },
    qualification: async () => ({ ok: state.qualified, errors: ['Profile invalid'], certificate: state.certificate, profile: state.profile }),
    effectiveBundleId: (_profile, bundle, target) => target || bundle,
    signer: { enqueue: (id) => { if (!state.enqueued.includes(id)) state.enqueued.push(id); } }, hashToken, publicBase: () => 'https://am.ayakameow.cn', audit: async (...args) => { if (state.auditFailure) throw new Error('fixture audit unavailable'); state.audit.push(args); } });
  const server = app.listen(0, '127.0.0.1'); await new Promise((r) => server.once('listening', r));
  t.after(async () => { await new Promise((r) => server.close(r)); fs.rmSync(dir, { recursive: true, force: true }); });
  const post = async (route, body, token = store.issue(identity)) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/app-update/${route}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
  };
  return { dir, state, post, ipa };
}

test('website binding requires its existing completed device session and the installed signing identity', async (t) => {
  const { post, state } = await harness(t);
  const body = { websiteSession: 'a'.repeat(48), ...identity, channel: 'stable' };
  let result = await post('link', body); assert.equal(result.status, 200); assert.equal(result.cache, 'no-store'); assert.equal(store.verify(result.body.token).teamId, identity.teamId);
  assert.equal((await post('link', { ...body, websiteSession: 'b'.repeat(48) })).status, 401);
  assert.equal((await post('link', { ...body, teamId: 'OTHER' })).status, 409);
  assert.equal((await post('link', { ...body, bundleId: 'other.app' })).status, 409);
  assert.equal((await post('link', { ...body, channel: 'beta' })).status, 403);
  state.device.allowed = 0; assert.equal((await post('link', body)).status, 403);
  assert.equal(state.enqueued.length, 0);
});

test('prepare uses existing bound certificate and is idempotent under concurrent retries', async (t) => {
  const { state, post } = await harness(t);
  const body = { requestId: crypto.randomUUID() }; const token = store.issue(identity);
  const [a, b] = await Promise.all([post('prepare', body, token), post('prepare', body, token)]);
  assert.equal(a.status, 200); assert.deepEqual(a.body, b.body); assert.match(a.body.manifestUrl, /^https:\/\/am\.ayakameow\.cn\/ota\/manifest\/[\w-]{43}$/);
  assert.deepEqual(state.enqueued, [1]); assert.equal(state.jobs[0].certificate_id, 4); assert.equal(state.jobs[0].profile_id, 3);
  assert.equal((await post('prepare', { requestId: crypto.randomUUID() })).status, 409);
  assert.ok(!JSON.stringify(a.body).includes('fixture-only-key'));
  state.jobs[0].status = 'succeeded'; state.jobs[0].output_path = null;
  assert.equal((await post('prepare', body, token)).status, 410);
});

test('authorization is rechecked, channels and teams stay isolated, older package never replaces the app', async (t) => {
  const { post, state, ipa } = await harness(t); const body = { requestId: crypto.randomUUID() };
  assert.equal((await post('prepare', body, 'forged')).status, 401);
  assert.equal((await post('prepare', { requestId: 'bad' })).status, 400);
  state.device.allowed = 0; assert.equal((await post('prepare', body)).status, 403); state.device.allowed = 1;
  state.profile.team_id = 'OTHER'; assert.equal((await post('prepare', body)).status, 409); state.profile.team_id = identity.teamId;
  state.application.target_bundle_id = 'other.app'; assert.equal((await post('prepare', body)).status, 409); delete state.application.target_bundle_id;
  state.qualified = false; assert.equal((await post('prepare', body)).status, 403); state.qualified = true;
  state.device.beta_access = 1; // Beta access must not redirect a stable installation into the Beta app.
  fixtureIpa(ipa, { AMProjReleaseCode: 176, AMProjReleaseChannel: 'stable' });
  assert.equal((await post('prepare', body)).body.current, true);
  fixtureIpa(ipa, { AMProjReleaseCode: 175, AMProjReleaseChannel: 'stable' });
  assert.equal((await post('prepare', body)).status, 409);
  fixtureIpa(ipa, { AMProjReleaseCode: 177, AMProjReleaseChannel: 'beta' });
  assert.equal((await post('prepare', body)).status, 409);
  assert.equal(state.jobs.length, 0);
});

test('signer embeds only a scoped capability before signing and leaves legacy IPA unchanged', { skip: spawnSync('zip', ['-h'], { windowsHide: true }).error ? 'zip command unavailable on this host' : false }, async (t) => {
  const { ipa, dir } = await harness(t);
  const original = fs.readFileSync(ipa);
  const prepared = await prepareUpdateIpa({ inputPath: ipa, workDir: dir, job: { device_id: 1, channel: 'production', profile_team_id: identity.teamId }, config: { publicBaseUrl: 'https://am.ayakameow.cn', encryptionKey: 'fixture-only-key' }, targetBundleId: identity.bundleId });
  const { info } = await ipaMetadata(prepared.inputPath);
  assert.equal(store.verify(info.AMAppUpdate.token).release, 177); assert.equal(store.verify(info.AMAppUpdate.token).deviceId, 1);
  assert.deepEqual(fs.readFileSync(ipa), original); assert.equal(info.CFBundleIdentifier, identity.bundleId);
  fixtureIpa(ipa, { AMProjReleaseCode: 175 });
  assert.deepEqual(await prepareUpdateIpa({ inputPath: ipa }), { inputPath: ipa, token: null });
});

test('integration is surgical and refuses ambiguous or already modified source anchors', () => {
  const server = "const { inspectIpa } = require('./ipa');\napp.post('/api/public/sign/:token', handler);\n  const initialized = await initDb();\n";
  const signer = "const { inspectSignedIpa } = require('./ipa');\nd.udid, a.ipa_path, a.bundle_id, a.target_bundle_id, p.bundle_id AS profile_bundle_id,\n  const queue = [];\n    if (!job) {\n    } finally {\n      for (const file\n      queue.push(Number(jobId));\n      const args = resolveTemplateArgs\n        input: inputPath,\n        const signedIpa = await inspectSignedIpa(outputPath);";
  const result = integrate(server, signer); assert.match(result.server, /registerAppUpdates\(app/); assert.match(result.signer, /input: prepared.inputPath/); assert.throws(() => integrate(result.server, result.signer));
});

test('an audit outage does not strand a committed job, retry safely resumes a queued job', async (t) => {
  const { post, state } = await harness(t); state.auditFailure = true;
  const token = store.issue(identity); const body = { requestId: crypto.randomUUID() };
  assert.equal((await post('prepare', body, token)).status, 200); assert.deepEqual(state.enqueued, [1]);
  state.enqueued.length = 0; // Simulate a process exiting after commit, before enqueue.
  assert.equal((await post('prepare', body, token)).status, 200); assert.deepEqual(state.enqueued, [1]); assert.equal(state.jobs.length, 1);
});

test('Beta retirement explicitly selects a separate production app, never uses the Beta default', async (t) => {
  const { post, state } = await harness(t); state.device.beta_access = 1;
  const linked = await post('link', { websiteSession: 'a'.repeat(48), bundleId: 'com.ayakameow.am.beta', channel: 'beta', release: 176, teamId: identity.teamId, migration: true });
  assert.equal(linked.status, 200); const claim = store.verify(linked.body.token);
  assert.equal(claim.channel, 'production'); assert.equal(claim.bundleId, identity.bundleId); assert.equal(claim.release, 0); assert.equal(claim.migrationFrom, 'com.ayakameow.am.beta'); assert.ok(claim.expires - claim.issued <= 900);
  assert.equal((await post('prepare', { requestId: crypto.randomUUID() }, linked.body.token)).status, 200);
});

test('startup recovery fails interrupted jobs and re-enqueues durable queued jobs', async () => {
  let failedRunning = false; const enqueued = [];
  await recoverSigningJobs({ prepare(sql) { return { run: async () => { assert.match(sql, /WHERE status = 'running'/); failedRunning = true; }, all: async () => { assert.match(sql, /WHERE status = 'queued'/); return [{ id: 9 }, { id: 10 }]; } }; } }, { enqueue: (id) => enqueued.push(id) });
  assert.equal(failedRunning, true); assert.deepEqual(enqueued, [9, 10]);
});
