'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { promisify } = require('node:util');
const { execFile } = require('node:child_process');
const run = promisify(execFile);

// This capability only authorizes updates for one device, channel and signing identity.
// Certificate material and its password never leave the signing service.
function capabilityStore(secret) {
  const mac = (purpose, value) => crypto.createHmac('sha256', secret).update(`am-app-update-v1/${purpose}\0${value}`).digest('base64url');
  return {
    issue(identity, now = Date.now(), ttl = 2 * 365 * 86400) {
      const payload = Buffer.from(JSON.stringify({ ...identity, v: 1, issued: Math.floor(now / 1000), expires: Math.floor(now / 1000) + ttl })).toString('base64url');
      return `${payload}.${mac('grant', payload)}`;
    },
    verify(token, now = Date.now()) {
      if (typeof token !== 'string' || token.length > 4096 || !/^[\w-]+\.[\w-]{43}$/.test(token)) return null;
      const [payload, signature] = token.split('.');
      if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(mac('grant', payload)))) return null;
      try {
        const claim = JSON.parse(Buffer.from(payload, 'base64url').toString());
        return claim.v === 1 && Number.isSafeInteger(claim.deviceId) && claim.deviceId > 0 &&
          ['production', 'beta'].includes(claim.channel) && typeof claim.bundleId === 'string' && claim.bundleId.length > 0 &&
          typeof claim.teamId === 'string' && claim.teamId.length > 0 &&
          Number.isSafeInteger(claim.release) && (claim.release >= 176 || (claim.release === 0 && claim.migrationFrom === 'com.ayakameow.am.beta' && claim.channel === 'production' && claim.bundleId === 'com.ayakameow.am')) &&
          claim.issued <= now / 1000 + 60 && claim.expires > now / 1000 ? claim : null;
      } catch (_) { return null; }
    },
    jobToken(token, requestId) { return mac('job', `${token}/${requestId}`); }
  };
}

function updateIdentity(device, application, material, effectiveBundleId) {
  return {
    deviceId: Number(device.id), channel: application.channel,
    bundleId: effectiveBundleId(material.profile?.bundle_id, application.bundle_id, application.target_bundle_id),
    teamId: String(material.profile?.team_id || ''),
  };
}

function matchesIdentity(claim, identity) {
  return ['deviceId', 'channel', 'bundleId', 'teamId'].every((key) => claim[key] === identity[key]);
}

async function ipaMetadata(filePath) {
  const unzipper = require('unzipper');
  const archive = await unzipper.Open.file(filePath);
  const entries = archive.files.filter((entry) => /^Payload\/[^/\\:]+\.app\/Info\.plist$/.test(entry.path));
  if (entries.length !== 1) throw new Error('更新包必须包含唯一主应用');
  const entry = entries[0];
  if (entry.uncompressedSize > 2 * 1024 * 1024) throw new Error('更新包元数据过大');
  const data = await entry.buffer();
  const info = data.subarray(0, 8).toString('ascii') === 'bplist00'
    ? require('bplist-parser').parseBuffer(data)[0] : require('plist').parse(data.toString('utf8'));
  return { entry, info };
}

async function prepareUpdateIpa({ inputPath, workDir, job, config, targetBundleId }) {
  const { entry, info } = await ipaMetadata(inputPath);
  const release = info.AMProjReleaseCode;
  const channel = info.AMProjReleaseChannel === 'stable' ? 'production' : info.AMProjReleaseChannel;
  if (!Number.isSafeInteger(release) || release < 176) return { inputPath, token: null };
  if (channel !== job.channel || !job.profile_team_id) throw new Error('更新包渠道或签名身份不匹配');
  const origin = new URL(config.publicBaseUrl);
  if (origin.protocol !== 'https:' || origin.hostname !== 'am.ayakameow.cn' || origin.port) throw new Error('更新服务地址必须使用正式 HTTPS 域名');
  const token = capabilityStore(config.encryptionKey).issue({ deviceId: Number(job.device_id), channel, bundleId: targetBundleId, teamId: job.profile_team_id, release });
  info.AMAppUpdate = { token, bundleId: targetBundleId, channel, release };
  const filePath = path.join(workDir, ...entry.path.split('/'));
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, require('plist').build(info), { mode: 0o600 });
  const prepared = path.join(workDir, 'update-source.ipa');
  fs.copyFileSync(inputPath, prepared);
  await run('zip', ['-q', prepared, entry.path], { cwd: workDir, timeout: 60000, windowsHide: true });
  return { inputPath: prepared, token };
}

function registerAppUpdates(app, services) {
  const { db, config, qualification, effectiveBundleId, signer, hashToken, publicBase, audit } = services;
  const capabilities = capabilityStore(config.encryptionKey);
  const fail = (res, status, error) => res.status(status).json({ ok: false, error });
  app.use('/api/app-update', (_req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });

  async function context(claim, executor = db) {
    const device = await executor.prepare('SELECT * FROM devices WHERE id = ?').get(claim.deviceId);
    if (!device || !device.allowed || (claim.channel === 'beta' && !Number(device.beta_access))) throw Object.assign(new Error('设备安装授权已失效，请联系管理员'), { status: 403 });
    const application = await executor.prepare('SELECT * FROM apps WHERE channel = ? AND is_default = 1 ORDER BY id DESC LIMIT 1').get(claim.channel);
    if (!application || !application.ipa_path || !fs.existsSync(application.ipa_path)) throw Object.assign(new Error('当前暂无可用安装包，请稍后再试或联系管理员'), { status: 404 });
    const check = await qualification(device, application);
    if (!check.ok) throw Object.assign(new Error(check.errors.join('；')), { status: 403 });
    if (!claim.teamId || !matchesIdentity(claim, updateIdentity(device, application, check, effectiveBundleId))) throw Object.assign(new Error('签名身份发生变化，无法直接覆盖更新，请先备份工程并联系管理员'), { status: 409 });
    return { device, application, check };
  }

  // One-time association uses the same authenticated device session as the website.
  app.post('/api/app-update/link', async (req, res) => {
    const session = String(req.body?.websiteSession || '');
    if (!/^[a-f0-9]{48}$/.test(session)) return fail(res, 401, '请先完成设备登记');
    const request = await db.prepare('SELECT * FROM udid_requests WHERE token_hash = ?').get(hashToken(session));
    if (!request || request.status !== 'completed' || !request.udid) return fail(res, 401, '请先完成设备登记');
    const device = await db.prepare('SELECT * FROM devices WHERE udid = ?').get(request.udid);
    const migration = req.body.migration === true && req.body.channel === 'beta' && req.body.bundleId === 'com.ayakameow.am.beta';
    const channel = migration ? 'production' : (req.body.channel === 'stable' ? 'production' : req.body.channel);
    const release = req.body.release;
    if (!['production', 'beta'].includes(channel) || !Number.isSafeInteger(release) || release < 176) return fail(res, 400, '安装版本不支持应用内更新');
    try {
      const application = migration ? await db.prepare('SELECT * FROM apps WHERE channel = ? AND is_default = 1 ORDER BY id DESC LIMIT 1').get('production') : null;
      if (migration && (!application || !application.ipa_path || !fs.existsSync(application.ipa_path))) return fail(res, 404, '当前暂无可用安装包，请稍后再试或联系管理员');
      const material = migration ? await qualification(device, application) : null;
      const claim = migration ? { ...updateIdentity(device || {}, application || {}, material || {}, effectiveBundleId), release: 0, migrationFrom: 'com.ayakameow.am.beta' } :
        { deviceId: Number(device?.id), channel, bundleId: req.body.bundleId, teamId: req.body.teamId, release };
      if (migration && (!material.ok || claim.bundleId !== 'com.ayakameow.am')) return fail(res, 409, '尚未配置可安装的正式版，请联系管理员');
      await context(claim);
      await audit('app-update', device.id, 'update_linked', { channel, release });
      return res.json({ ok: true, token: capabilities.issue(claim, Date.now(), migration ? 15 * 60 : 2 * 365 * 86400) });
    } catch (error) { return fail(res, error.status || 400, error.message); }
  });

  app.post('/api/app-update/prepare', async (req, res) => {
    const token = String(req.get('authorization') || '').replace(/^Bearer /, '');
    const claim = capabilities.verify(token);
    if (!claim) return fail(res, 401, '更新关联已失效，请重新关联设备');
    const requestId = String(req.body?.requestId || '');
    if (!/^[a-f0-9-]{36}$/i.test(requestId)) return fail(res, 400, '更新请求标识无效');
    const jobToken = capabilities.jobToken(token, requestId);
    try {
      const outcome = await db.transaction(async (tx) => {
        await tx.prepare('SELECT id FROM devices WHERE id = ? FOR UPDATE').get(claim.deviceId);
        const { application, check } = await context(claim, tx);
        const { info } = await ipaMetadata(application.ipa_path);
        if (info.AMProjReleaseChannel !== (claim.channel === 'production' ? 'stable' : 'beta') ||
          !Number.isSafeInteger(info.AMProjReleaseCode)) throw Object.assign(new Error('管理员尚未发布可用于应用内更新的安装包'), { status: 409 });
        if (info.AMProjReleaseCode < 176) throw Object.assign(new Error('管理员尚未发布可用于应用内更新的安装包'), { status: 409 });
        if (info.AMProjReleaseCode <= claim.release) return { current: true };
        const existing = await tx.prepare('SELECT * FROM sign_jobs WHERE public_token_hash = ?').get(hashToken(jobToken));
        if (existing) {
          if (Number(existing.app_id) !== Number(application.id)) throw Object.assign(new Error('安装包已更新，请重新开始更新'), { status: 410 });
          if (existing.status === 'failed' || (existing.status === 'succeeded' && (!existing.output_path || !fs.existsSync(existing.output_path)))) throw Object.assign(new Error('上次更新任务已失效，请重新开始'), { status: 410 });
          return { id: existing.id, resumed: true, status: existing.status };
        }
        const active = await tx.prepare("SELECT id FROM sign_jobs WHERE device_id = ? AND status IN ('queued', 'running') LIMIT 1 FOR UPDATE").get(claim.deviceId);
        if (active) throw Object.assign(new Error('设备已有安装任务正在处理，请稍后重试'), { status: 409 });
        // Prevent switching the default package between validation and job creation.
        const locked = await tx.prepare('SELECT id FROM apps WHERE channel = ? AND is_default = 1 ORDER BY id DESC LIMIT 1 FOR UPDATE').get(claim.channel);
        if (Number(locked?.id) !== Number(application.id)) throw Object.assign(new Error('目标版本刚刚发生变化，请重试'), { status: 409 });
        const result = await tx.prepare('INSERT INTO sign_jobs (device_id, app_id, certificate_id, profile_id, public_token_hash) VALUES (?, ?, ?, ?, ?)').run(claim.deviceId, application.id, check.certificate.id, check.profile.id, hashToken(jobToken));
        return { id: result.lastInsertRowid, resumed: false, status: 'queued' };
      });
      if (outcome.current) return res.json({ ok: true, current: true });
      if (outcome.status === 'queued') signer.enqueue(outcome.id);
      if (!outcome.resumed) await audit('app-update', claim.deviceId, 'update_requested', { jobId: outcome.id, channel: claim.channel }).catch(() => console.error('[app-update] audit temporarily unavailable'));
      return res.json({ ok: true, statusUrl: `${publicBase(req)}/api/public/jobs/${jobToken}`, manifestUrl: `${publicBase(req)}/ota/manifest/${jobToken}` });
    } catch (error) { return fail(res, error.code === 'ENOENT' ? 404 : error.status || 400, error.code === 'ENOENT' ? '当前暂无可用安装包，请稍后再试或联系管理员' : error.message); }
  });

  app.post('/api/app-update/ready', async (req, res) => {
    const token = String(req.get('authorization') || '').replace(/^Bearer /, '');
    const claim = capabilities.verify(token);
    if (!claim) return fail(res, 401, '更新关联已失效，请重新关联设备');
    const requestId = String(req.body?.requestId || '');
    if (!/^[a-f0-9-]{36}$/i.test(requestId)) return fail(res, 400, '更新请求标识无效');
    try {
      const { application } = await context(claim);
      const jobToken = capabilities.jobToken(token, requestId);
      const job = await db.prepare('SELECT * FROM sign_jobs WHERE public_token_hash = ?').get(hashToken(jobToken));
      if (!job || Number(job.app_id) !== Number(application.id)) return fail(res, 410, '安装包已更新或移除，请重新检查更新');
      if (job.status !== 'succeeded') return fail(res, 409, '安装包尚未准备完成，请稍后重试');
      if (!job.output_path || !fs.existsSync(job.output_path)) return fail(res, 410, '安装文件已失效，请重新开始更新');
      return res.json({ ok: true, manifestUrl: `${publicBase(req)}/ota/manifest/${jobToken}` });
    } catch (error) { return fail(res, error.status || 400, error.message); }
  });
}

async function recoverSigningJobs(db, signer) {
  await db.prepare("UPDATE sign_jobs SET status = 'failed', error_message = ?, completed_at = UTC_TIMESTAMP(3) WHERE status = 'running'").run('签名服务已重启，上次任务未完成，请重试');
  const jobs = await db.prepare("SELECT id FROM sign_jobs WHERE status = 'queued' ORDER BY id").all();
  for (const job of jobs) signer.enqueue(job.id);
}

async function appUpdateJobIsCurrent(db, token, appId) {
  // App-update job capabilities are 43-character HMACs; website job tokens remain 48 hex characters.
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return true;
  const current = await db.prepare('SELECT id FROM apps WHERE channel = (SELECT channel FROM apps WHERE id = ?) AND is_default = 1 ORDER BY id DESC LIMIT 1').get(appId);
  return Boolean(current) && Number(current.id) === Number(appId);
}

module.exports = { capabilityStore, matchesIdentity, prepareUpdateIpa, registerAppUpdates, recoverSigningJobs, appUpdateJobIsCurrent, ipaMetadata };
