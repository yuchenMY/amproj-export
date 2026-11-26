// Generated from the verified website server snapshot a5f2ee41; do not edit manually.
app.post('/api/admin/apps', requireAdmin, requireCsrf, ipaUpload.single('ipa'), async (req, res) => {
  const file = req.file;
  if (!file) return jsonError(res, 400, '请选择 IPA 文件');
  let storedPath = '';
  try {
    const channel = normalizeReleaseChannel(req.body.channel);
    if (!channel) throw new Error('请选择正式版或测试版发布渠道');
    const targetBundleId = channel === 'beta' ? normalizeBundleId(req.body.targetBundleId) : null;
    if (channel === 'beta' && !targetBundleId) {
      throw new Error('测试版必须填写有效的独立 Bundle ID，例如 com.ayakameow.am.beta');
    }
    const productionBundleId = normalizeBundleId(config.outputBundleId);
    if (channel === 'beta' && productionBundleId && targetBundleId.toLowerCase() === productionBundleId.toLowerCase()) {
      throw new Error('测试版 Bundle ID 不能与正式版相同，否则安装时会覆盖正式版');
    }
    const info = await inspectIpa(file.path);
    const releaseDir = path.join(config.privateDir, 'apps', channel);
    fs.mkdirSync(releaseDir, { recursive: true });
    storedPath = path.join(releaseDir, `${randomToken(18)}.ipa`);
    fs.renameSync(file.path, storedPath);
    const saved = await db.transaction(async (tx) => {
      const existingCount = (await tx.prepare('SELECT COUNT(*) AS count FROM apps WHERE channel = ?').get(channel)).count;
      const result = await tx.prepare('INSERT INTO apps (name, file_name, ipa_path, bundle_id, version, build, channel, target_bundle_id, is_default) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
        .run(String(req.body.name || info.name).slice(0, 160), file.originalname || file.filename, path.resolve(storedPath), info.bundleId, info.version, info.build, channel, targetBundleId, existingCount === 0 ? 1 : 0);
      const application = await tx.prepare('SELECT id, name, file_name, bundle_id, version, build, channel, target_bundle_id, is_default FROM apps WHERE id = ?').get(result.lastInsertRowid);
      await tx.prepare('INSERT INTO audit_logs (actor_type, actor_id, action, detail_json) VALUES (?, ?, ?, ?)')
        .run('admin', String(req.admin.admin_id), 'ipa_uploaded', JSON.stringify({ appId: result.lastInsertRowid, bundleId: info.bundleId, channel }));
      return application;
    });
    return res.json({ ok: true, app: saved });
  } catch (error) {
    try { fs.rmSync(file.path, { force: true }); } catch (_) {}
    if (storedPath) {
      try { fs.rmSync(storedPath, { force: true }); } catch (_) {}
    }
    return res.status(400).json({ ok: false, error: String(error.message || error) });
  }
});

app.patch('/api/admin/apps/:id/default', requireAdmin, requireCsrf, async (req, res) => {
  const id = safeInt(req.params.id);
  const application = await db.prepare('SELECT id, channel FROM apps WHERE id = ?').get(id);
  if (!application) return jsonError(res, 404, '应用不存在');
  await db.transaction(async (tx) => {
    await tx.prepare('UPDATE apps SET is_default = 0 WHERE channel = ?').run(application.channel);
    await tx.prepare('UPDATE apps SET is_default = 1 WHERE id = ?').run(id);
  });
  await audit('admin', req.admin.admin_id, 'default_app_changed', { appId: id, channel: application.channel });
  return res.json({ ok: true });
});

app.delete('/api/admin/apps/:id', requireAdmin, requireCsrf, async (req, res) => {
  const id = safeInt(req.params.id);
  if (!id) return jsonError(res, 400, '应用 ID 不正确');

  let deleted;
  try {
    deleted = await db.transaction(async (tx) => {
      const application = await tx.prepare('SELECT * FROM apps WHERE id = ? FOR UPDATE').get(id);
      if (!application) throw Object.assign(new Error('应用不存在'), { status: 404 });
      const activeJob = await tx.prepare("SELECT id FROM sign_jobs WHERE app_id = ? AND status IN ('queued', 'running') LIMIT 1 FOR UPDATE").get(id);
      if (activeJob) {
        throw Object.assign(new Error('该应用仍有签名任务正在处理，请等待任务完成后再删除'), {
          status: 409,
          details: { jobId: activeJob.id }
        });
      }
      const jobs = await tx.prepare('SELECT id, output_path FROM sign_jobs WHERE app_id = ?').all(id);
      await tx.prepare('DELETE FROM apps WHERE id = ?').run(id);
      let defaultAppId = null;
      if (application.is_default) {
        const fallback = await tx.prepare('SELECT id FROM apps WHERE channel = ? ORDER BY id DESC LIMIT 1 FOR UPDATE').get(application.channel);
        if (fallback) {
          defaultAppId = fallback.id;
          await tx.prepare('UPDATE apps SET is_default = 1 WHERE id = ?').run(fallback.id);
        }
      }
      return { application, jobs, defaultAppId };
    });
  } catch (error) {
    return jsonError(res, error.status || 400, String(error.message || error), error.details);
  }

  const fileResults = [
    removeManagedFile(deleted.application.ipa_path, path.join(config.privateDir, 'apps')),
    ...deleted.jobs.map((job) => removeManagedFile(job.output_path, config.outputDir))
  ];
  const cleanupWarnings = fileResults.filter((result) => result.skipped || result.error);
  await audit('admin', req.admin.admin_id, 'ipa_deleted', {
    appId: id,
    name: deleted.application.name,
    defaultAppId: deleted.defaultAppId,
    deletedJobCount: deleted.jobs.length,
    cleanupWarnings
  });
  return res.json({
    ok: true,
    message: cleanupWarnings.length ? '应用记录已删除，部分异常路径未清理' : '应用及相关签名文件已删除',
    defaultAppId: deleted.defaultAppId,
    cleanupWarnings
  });
});

