'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { renderUdidHandoff } = require('./udid-handoff');
function once(source, before, after) {
  if (source.split(before).length !== 2) throw new Error('Device registration integration anchor changed');
  return source.replace(before, after);
}
function integrateRegistration(source) {
  source = source.replace(/\r\n/g, '\n');
  if (source.includes('function renderUdidHandoff(')) throw new Error('Device registration integration anchor changed: already integrated');
  source = once(source, '  async function startUdid() {', renderUdidHandoff.toString() + '\n\n  async function startUdid() {');
  source = once(source, '    state.token = token || null;', '    state.token = token || null;\n    renderUdidHandoff(state.token, Boolean(state.summary?.udid));');
  source = once(source, '    const hasDevice = Boolean(summary?.udid);', '    const hasDevice = Boolean(summary?.udid);\n    renderUdidHandoff(state.token, hasDevice);');
  return source;
}
if (require.main === module) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output || path.resolve(input) === path.resolve(output)) throw new Error('Usage: node integrate-registration.cjs SOURCE_APP_JS STAGED_APP_JS');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, integrateRegistration(fs.readFileSync(input, 'utf8')));
  console.log('UDID_SAFARI_HANDOFF_STAGED');
}
module.exports = { integrateRegistration };
