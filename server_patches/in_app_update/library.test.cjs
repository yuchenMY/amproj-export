'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const express = require('express');
const { integrateLibraryRoutes, guardAppUpdateOta } = require('./integrate-library.cjs');
const { appUpdateJobIsCurrent } = require('./in-app-update');
const before = fs.readFileSync(path.join(__dirname, 'fixtures/library-routes-before.js'), 'utf8');
const adminBefore = "这是当前渠道版本，删除后系统只会从同一渠道中选择替代版本。\nshowNotice('#app-notice', `应用已发布：${data.app.name} · ${data.app.target_bundle_id || dashboard.outputBundleId || data.app.bundle_id}`, 'good');";

async function harness(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'meow-library-'));
  const privateDir = path.join(directory, 'private'); const outputDir = path.join(directory, 'signed');
  fs.mkdirSync(outputDir, { recursive: true });
  const state = { apps: [], jobs: [], next: 1, active: false, failInsert: false };
  const db = {
    async transaction(callback) {
      const snapshot = structuredClone({ apps: state.apps, jobs: state.jobs });
      try { return await callback(db); } catch (error) { state.apps = snapshot.apps; state.jobs = snapshot.jobs; throw error; }
    },
    prepare(sql) { return {
      async get(id) {
        if (sql.includes('FROM apps') && sql.includes('WHERE id = ?')) return state.apps.find((app) => app.id === id);
        if (sql.includes('FROM sign_jobs') && sql.includes("status IN ('queued', 'running')")) return state.active ? { id: 8 } : undefined;
        throw new Error('Unexpected library get: ' + sql);
      },
      async all(id) { assert.ok(sql.includes('FROM sign_jobs')); return state.jobs.filter((job) => job.app_id === id); },
      async run(...args) {
        if (sql.startsWith('UPDATE apps SET is_default = 0')) { for (const app of state.apps) if (app.channel === args[0]) app.is_default = 0; }
        else if (sql.startsWith('UPDATE apps SET is_default = 1')) state.apps.find((app) => app.id === args[0]).is_default = 1;
        else if (sql.startsWith('INSERT INTO apps')) {
          if (state.failInsert) throw new Error('fixture insertion failure');
          const id = state.next++; const [name, file_name, ipa_path, bundle_id, version, build, channel, target_bundle_id, is_default] = args;
          state.apps.push({ id, name, file_name, ipa_path, bundle_id, version, build, channel, target_bundle_id, is_default }); return { lastInsertRowid: id };
        } else if (sql.startsWith('DELETE FROM apps')) { state.apps = state.apps.filter((app) => app.id !== args[0]); state.jobs = state.jobs.filter((job) => job.app_id !== args[0]); }
        else assert.ok(sql.startsWith('INSERT INTO audit_logs'), sql);
        return { lastInsertRowid: 0 };
      }
    }; }
  };
  const app = express(); app.use(express.json());
  const authorize = (req, _res, next) => { req.admin = { admin_id: 1 }; next(); };
  const upload = { single: () => (req, _res, next) => {
    const filename = path.join(directory, crypto.randomUUID() + '.ipa'); fs.writeFileSync(filename, 'fixture IPA');
    req.file = { path: filename, originalname: 'fixture.ipa' }; next();
  } };
  vm.runInNewContext(integrateLibraryRoutes(before), { app, requireAdmin: authorize, requireCsrf: (_req, _res, next) => next(), ipaUpload: upload,
    fs, path, db, config: { privateDir, outputDir, outputBundleId: 'com.ayakameow.am' },
    normalizeReleaseChannel: (value) => ['production', 'beta'].includes(value) ? value : null,
    normalizeBundleId: (value) => typeof value === 'string' && value.includes('.') ? value : null,
    inspectIpa: async () => ({ name: 'fixture', bundleId: 'com.ayakameow.am', version: '6.2.58', build: '865' }),
    randomToken: () => crypto.randomBytes(18).toString('hex'), safeInt: (value) => Number(value), audit: async () => {},
    jsonError: (res, status, error) => res.status(status).json({ ok: false, error }),
    removeManagedFile: (file, root) => { assert.ok(path.resolve(file).startsWith(path.resolve(root) + path.sep)); fs.rmSync(file, { force: true }); return { removed: true }; }
  });
  const server = app.listen(0, '127.0.0.1'); await new Promise((r) => server.once('listening', r));
  t.after(async () => { await new Promise((r) => server.close(r)); fs.rmSync(directory, { recursive: true, force: true }); });
  const request = async (method, suffix = '', body = {}) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/admin/apps${suffix}`, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  return { state, request, directory, outputDir };
}

test('real website upload routes make the latest upload current only within its channel', async (t) => {
  const { state, request } = await harness(t);
  const first = await request('POST', '', { channel: 'production' }); assert.equal(first.status, 200);
  const beta = await request('POST', '', { channel: 'beta', targetBundleId: 'com.ayakameow.am.beta' }); assert.equal(beta.status, 200);
  const latest = await request('POST', '', { channel: 'production' }); assert.equal(latest.status, 200);
  assert.equal(state.apps.find((app) => app.id === first.body.app.id).is_default, 0);
  assert.equal(state.apps.find((app) => app.id === beta.body.app.id).is_default, 1);
  assert.equal(state.apps.find((app) => app.id === latest.body.app.id).is_default, 1);
  state.failInsert = true; assert.equal((await request('POST', '', { channel: 'production' })).status, 400);
  assert.equal(state.apps.find((app) => app.id === latest.body.app.id).is_default, 1);
});

test('actual OTA routes refuse old app-update packages even when the current package changes after ready', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'meow-ota-')); const output = path.join(directory, 'fixture.ipa'); fs.writeFileSync(output, 'signed fixture IPA');
  const appToken = 'A'.repeat(43), websiteToken = 'b'.repeat(48); let currentId = 7;
  const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex');
  const hashes = new Set([hashToken(appToken), hashToken(websiteToken)]);
  const db = { prepare(sql) { return { get: async (value) => {
    if (sql.startsWith('SELECT id FROM apps WHERE channel')) return currentId ? { id: currentId } : undefined;
    return hashes.has(value) ? { app_id: 7, status: 'succeeded', output_path: output, file_name: 'fixture.ipa', version: '6.2.58' } : undefined;
  } }; } };
  const app = express();
  const routes = fs.readFileSync(path.join(__dirname, 'fixtures/ota-routes-before.js'), 'utf8');
  vm.runInNewContext(guardAppUpdateOta(routes), { app, db, fs, path, hashToken, appUpdateJobIsCurrent, publicBase: () => 'https://am.ayakameow.cn',
    effectiveBundleId: () => 'com.ayakameow.am', inspectIpa: async () => ({ name: 'fixture' }), buildManifest: () => '<plist/>', audit: async () => {}, safeDownloadName: () => 'fixture.ipa' });
  const server = app.listen(0, '127.0.0.1'); await new Promise((r) => server.once('listening', r));
  t.after(async () => { await new Promise((r) => server.close(r)); fs.rmSync(directory, { recursive: true, force: true }); });
  const get = async (route, token) => { const response = await fetch(`http://127.0.0.1:${server.address().port}/ota/${route}/${token}`); await response.text(); return response.status; };
  assert.equal(await get('manifest', appToken), 200); assert.equal(await get('ipa', appToken), 200);
  currentId = 8; assert.equal(await get('manifest', appToken), 410); assert.equal(await get('ipa', appToken), 410);
  assert.equal(await get('manifest', websiteToken), 200); assert.equal(await get('ipa', websiteToken), 200);
  currentId = null; assert.equal(await get('manifest', appToken), 410); assert.equal(await get('ipa', appToken), 410);
});

test('real delete route removes current package and signed files without reviving an old version', async (t) => {
  const { state, request, outputDir } = await harness(t);
  const old = (await request('POST', '', { channel: 'production' })).body.app;
  const current = (await request('POST', '', { channel: 'production' })).body.app;
  const signed = path.join(outputDir, 'fixture-signed.ipa'); fs.writeFileSync(signed, 'fixture signed IPA'); state.jobs.push({ id: 7, app_id: current.id, output_path: signed });
  state.active = true; assert.equal((await request('DELETE', '/' + current.id)).status, 409); assert.equal(fs.existsSync(current.ipa_path), true);
  state.active = false; const deleted = await request('DELETE', '/' + current.id); assert.equal(deleted.status, 200); assert.equal(deleted.body.defaultAppId, null);
  assert.equal(state.apps.some((app) => app.channel === 'production' && app.is_default), false);
  assert.equal(fs.existsSync(current.ipa_path), false); assert.equal(fs.existsSync(signed), false); assert.equal(fs.existsSync(old.ipa_path), true);
  const replacement = await request('POST', '', { channel: 'production' }); assert.equal(replacement.body.app.is_default, 1);
});
