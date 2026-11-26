// Generated from the verified website server snapshot a5f2ee41; do not edit manually.
app.get('/ota/manifest/:token', async (req, res) => {
  const token = String(req.params.token || '');
  const job = await db.prepare(`SELECT j.*, a.name AS app_name, a.version, a.bundle_id, a.target_bundle_id, p.bundle_id AS profile_bundle_id
    FROM sign_jobs j JOIN apps a ON a.id = j.app_id LEFT JOIN provisioning_profiles p ON p.id = j.profile_id
    WHERE j.public_token_hash = ?`).get(hashToken(token));
  if (!job || job.status !== 'succeeded' || !job.output_path || !fs.existsSync(job.output_path)) return res.status(404).send('签名包不存在');
  const ipaUrl = `${publicBase(req)}/ota/ipa/${encodeURIComponent(token)}`;
  const signedInfo = await inspectIpa(job.output_path);
  return res.type('application/xml').set('Cache-Control', 'no-store').send(buildManifest({ ipaUrl, bundleId: effectiveBundleId(job.profile_bundle_id, job.bundle_id, job.target_bundle_id), title: signedInfo.name, version: job.version }));
});

app.get('/ota/ipa/:token', async (req, res) => {
  const token = String(req.params.token || '');
  const job = await db.prepare('SELECT j.*, a.file_name FROM sign_jobs j JOIN apps a ON a.id = j.app_id WHERE j.public_token_hash = ?').get(hashToken(token));
  if (!job || job.status !== 'succeeded' || !job.output_path || !fs.existsSync(job.output_path)) return res.status(404).send('签名包不存在');
  await audit('public', hashToken(token).slice(0, 12), 'ipa_downloaded', { jobId: job.id });
  return res.type('application/octet-stream').set('Content-Disposition', `attachment; filename="${safeDownloadName(job.file_name || `signed-${job.id}.ipa`)}"`).sendFile(path.resolve(job.output_path));
});

