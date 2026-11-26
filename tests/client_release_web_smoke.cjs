const vm = require('node:vm');
const assert = require('node:assert/strict');
const calls = [];
class XHR {
  constructor() { this.headers = {}; }
  open() {}
  send() {}
  setRequestHeader(k,v) { this.headers[k] = v; }
}
const context = { location: new URL('https://am.meowcr.cn/me.html'), URL, Headers, XMLHttpRequest: XHR };
context.window = { fetch: (...args) => { calls.push(args); return Promise.resolve(); } };
vm.createContext(context);
vm.runInContext(`// AMPROJ_WEB_SCRIPT`, context);
context.window.fetch('/api/user/me',{headers:{Authorization:'Bearer fixture'},method:'POST',body:'content'});
assert.equal(calls[0][1].headers.get('Authorization'),'Bearer fixture');
assert.equal(calls[0][1].headers.get('X-AM-Release-Code'),'174');
assert.equal(calls[0][1].body,'content');
context.window.fetch(new URL('https://am.meowcr.cn/api/support/tickets'));
assert.equal(calls[1][1].headers.get('X-AM-Release-Channel'),'beta');
const external = { headers:{Authorization:'unrelated'} };
context.window.fetch('https://other.test/api/',external);
assert.equal(calls[2][1],external);
const request = { url:'https://am.meowcr.cn/api/cloud/projects',headers:new Headers({Authorization:'Bearer request'}) };
context.window.fetch(request);
assert.equal(calls[3][1].headers.get('Authorization'),'Bearer request');
const xhr = new XHR(); xhr.open('GET','/api/user/me');xhr.send();assert.equal(xhr.headers['X-AM-Release-Code'],'174');
xhr.headers={};xhr.open('GET','https://other.test/api/');xhr.send();assert.deepEqual(xhr.headers,{});
console.log('CLIENT_RELEASE_WEB_PASS');
