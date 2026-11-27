'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderUdidHandoff } = require('./udid-handoff');
const { integrateRegistration } = require('./integrate-registration.cjs');

function fixture() {
  const nodes = new Map();
  const element = tag => ({ tag, style: {}, children: [], handlers: {}, value: '',
    append(...children) { this.children.push(...children); },
    setAttribute() {}, focus() { this.focused = true; }, select() { this.selected = true; },
    addEventListener(name, handler) { this.handlers[name] = handler; },
    querySelector(tag) { return this.children.find(item => item.tag === tag); },
    remove() { nodes.delete(this.id); },
    insertAdjacentElement(position, item) { assert.equal(position, 'afterend'); nodes.set(item.id, item); }
  });
  nodes.set('action-notice', element('div'));
  return { document: { getElementById: key => nodes.get(key), createElement: element, execCommand: () => false }, navigator: {}, nodes };
}
test('Safari handoff uses the existing request, survives polling, clears after completion, rejects invalid tokens', async () => {
  const env = fixture(), token = 'a'.repeat(48);
  let clipboard;
  env.navigator.clipboard = { async writeText(value) { clipboard = value; } };
  renderUdidHandoff(token, false, env);
  const panel = env.nodes.get('udid-safari-handoff');
  assert.equal(panel.querySelector('input').value, 'https://am.ayakameow.cn/udid/mobileconfig/' + token);
  renderUdidHandoff(token, false, env);
  assert.equal(env.nodes.get('udid-safari-handoff'), panel);
  await panel.querySelector('button').handlers.click();
  assert.equal(clipboard, panel.querySelector('input').value);
  assert.match(panel.querySelector('button').textContent, /已复制/);
  renderUdidHandoff(token, true, env);
  assert.equal(env.nodes.size, 1);
  for (const value of [null, '', '<script>', 'a'.repeat(47), 'https://other.example']) renderUdidHandoff(value, false, env);
  assert.equal(env.nodes.size, 1);
});
test('denied clipboard never claims success and leaves a selectable link', async () => {
  const env = fixture();
  env.navigator.clipboard = { async writeText() { throw new Error('denied'); } };
  renderUdidHandoff('b'.repeat(48), false, env);
  const panel = env.nodes.get('udid-safari-handoff');
  await panel.querySelector('button').handlers.click();
  assert.equal(panel.querySelector('input').selected, true);
  assert.match(panel.querySelector('button').textContent, /长按/);
  env.document.execCommand = () => true;
  await panel.querySelector('button').handlers.click();
  assert.match(panel.querySelector('button').textContent, /已复制/);
});
test('registration integration updates unique live anchors and refuses duplicate application', () => {
  const source = "  async function startUdid() {\n    state.token = token || null;\n    const hasDevice = Boolean(summary?.udid);\n  }";
  const result = integrateRegistration(source);
  assert.match(result, /function renderUdidHandoff/);
  assert.match(result, /renderUdidHandoff\(state.token, hasDevice\)/);
  assert.throws(() => integrateRegistration(result), /anchor changed/);
});
