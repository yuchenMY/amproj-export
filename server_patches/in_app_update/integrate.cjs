'use strict';
const fs = require('node:fs');
const path = require('node:path');

function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2) throw new Error(`Integration anchor changed: ${before.slice(0, 80)}`);
  return source.replace(before, after);
}

function integrate(server, signer) {
  server = server.replace(/\r\n/g, '\n'); signer = signer.replace(/\r\n/g, '\n');
  server = replaceOnce(server, "const { inspectIpa } = require('./ipa');", "const { inspectIpa } = require('./ipa');\nconst { registerAppUpdates, recoverSigningJobs } = require('./in-app-update');");
  server = replaceOnce(server, "app.post('/api/public/sign/:token',", "registerAppUpdates(app, { db, config, qualification, effectiveBundleId, signer, hashToken, publicBase, audit });\n\napp.post('/api/public/sign/:token',");
  server = replaceOnce(server, '  const initialized = await initDb();', '  const initialized = await initDb();\n  await recoverSigningJobs(db, signer);');
  signer = replaceOnce(signer, "const { inspectSignedIpa } = require('./ipa');", "const { inspectSignedIpa } = require('./ipa');\nconst { prepareUpdateIpa, ipaMetadata } = require('./in-app-update');");
  signer = replaceOnce(signer, 'd.udid, a.ipa_path, a.bundle_id, a.target_bundle_id, p.bundle_id AS profile_bundle_id,', 'd.udid, a.ipa_path, a.bundle_id, a.target_bundle_id, a.channel, p.team_id AS profile_team_id, p.bundle_id AS profile_bundle_id,');
  signer = replaceOnce(signer, '  const queue = [];', '  const queue = [];\n  const pendingJobs = new Set();');
  signer = replaceOnce(signer, '    if (!job) {', "    if (!job || job.status !== 'queued') {\n      pendingJobs.delete(jobId);");
  signer = replaceOnce(signer, '    } finally {\n      for (const file', '    } finally {\n      pendingJobs.delete(jobId);\n      for (const file');
  signer = replaceOnce(signer, '      queue.push(Number(jobId));', '      const id = Number(jobId);\n      if (pendingJobs.has(id)) return;\n      pendingJobs.add(id);\n      queue.push(id);');
  signer = replaceOnce(signer, '      const args = resolveTemplateArgs', '      const prepared = await prepareUpdateIpa({ inputPath, workDir, job, config, targetBundleId });\n      const args = resolveTemplateArgs');
  signer = replaceOnce(signer, '        input: inputPath,', '        input: prepared.inputPath,');
  signer = replaceOnce(signer, '        const signedIpa = await inspectSignedIpa(outputPath);', '        const signedIpa = await inspectSignedIpa(outputPath);\n        if (prepared.token) {\n          const { info } = await ipaMetadata(outputPath);\n          if (info.AMAppUpdate?.token !== prepared.token) throw new Error("Update authorization missing from signed IPA");\n        }');
  return { server, signer };
}

if (require.main === module) {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination || path.resolve(source) === path.resolve(destination)) throw new Error('Usage: node integrate.cjs SOURCE_APP_DIRECTORY STAGING_DIRECTORY');
  const result = integrate(fs.readFileSync(path.join(source, 'src/server.js'), 'utf8'), fs.readFileSync(path.join(source, 'src/signer.js'), 'utf8'));
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(path.join(destination, 'server.js'), result.server);
  fs.writeFileSync(path.join(destination, 'signer.js'), result.signer);
  fs.copyFileSync(path.join(__dirname, 'in-app-update.js'), path.join(destination, 'in-app-update.js'));
  console.log('APP_UPDATE_INTEGRATION_STAGED');
}
module.exports = { integrate };
