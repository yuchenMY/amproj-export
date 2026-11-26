'use strict';
const fs = require('node:fs');
const path = require('node:path');

function once(source, before, after) {
  if (source.split(before).length !== 2) throw new Error('Application library integration anchor changed');
  return source.replace(before, after);
}

function integrateLibraryRoutes(server) {
  server = server.replace(/\r\n/g, '\n');
  server = once(server, "      const existingCount = (await tx.prepare('SELECT COUNT(*) AS count FROM apps WHERE channel = ?').get(channel)).count;", "      await tx.prepare('UPDATE apps SET is_default = 0 WHERE channel = ?').run(channel);");
  server = once(server, 'existingCount === 0 ? 1 : 0', '1');
  const fallback = "      if (application.is_default) {\n        const fallback = await tx.prepare('SELECT id FROM apps WHERE channel = ? ORDER BY id DESC LIMIT 1 FOR UPDATE').get(application.channel);\n        if (fallback) {\n          defaultAppId = fallback.id;\n          await tx.prepare('UPDATE apps SET is_default = 1 WHERE id = ?').run(fallback.id);\n        }\n      }";
  server = once(server, fallback, '      // Removed current packages stay unavailable until explicitly replaced or selected.');
  return server;
}

function guardAppUpdateOta(server) {
  const check = "  if (!job || job.status !== 'succeeded' || !job.output_path || !fs.existsSync(job.output_path)) return res.status(404).send('签名包不存在');";
  if (server.split(check).length !== 3) throw new Error('OTA integration anchors changed');
  return server.split(check).join(check + "\n  if (!await appUpdateJobIsCurrent(db, token, job.app_id)) return res.status(410).send('安装包已更新或移除，请重新检查更新');");
}

function integrateLibrary(server, admin) {
  server = integrateLibraryRoutes(server); admin = admin.replace(/\r\n/g, '\n');
  server = once(server, "const { registerAppUpdates, recoverSigningJobs } = require('./in-app-update');", "const { registerAppUpdates, recoverSigningJobs, appUpdateJobIsCurrent } = require('./in-app-update');");
  server = guardAppUpdateOta(server);
  admin = once(admin, '这是当前渠道版本，删除后系统只会从同一渠道中选择替代版本。', '这是当前渠道版本，删除后该渠道将暂无可用安装包，不会自动启用历史版本。');
  admin = once(admin, "showNotice('#app-notice', `应用已发布：${data.app.name} · ${data.app.target_bundle_id || dashboard.outputBundleId || data.app.bundle_id}`, 'good');", "showNotice('#app-notice', `安装包已上传并设为当前版本：${data.app.name}，App 更新已同步。`, 'good');");
  return { server, admin };
}

function extractLibraryRoutes(server) {
  return server.slice(server.indexOf("app.post('/api/admin/apps',"), server.indexOf("app.delete('/api/admin/certificates/:id',"));
}

function extractOtaRoutes(server) {
  return server.slice(server.indexOf("app.get('/ota/manifest/:token',"), server.indexOf("app.post('/api/admin/login',"));
}

if (require.main === module) {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination || path.resolve(source) === path.resolve(destination)) throw new Error('Usage: node integrate-library.cjs WEBSITE_DIRECTORY STAGING_DIRECTORY');
  const result = integrateLibrary(fs.readFileSync(path.join(source, 'src/server.js'), 'utf8'), fs.readFileSync(path.join(source, 'public/admin.js'), 'utf8'));
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(path.join(destination, 'server.js'), result.server);
  fs.writeFileSync(path.join(destination, 'admin.js'), result.admin);
  fs.copyFileSync(path.join(__dirname, 'in-app-update.js'), path.join(destination, 'in-app-update.js'));
  console.log('APP_LIBRARY_INTEGRATION_STAGED');
}
module.exports = { integrateLibrary, integrateLibraryRoutes, guardAppUpdateOta, extractLibraryRoutes, extractOtaRoutes };
