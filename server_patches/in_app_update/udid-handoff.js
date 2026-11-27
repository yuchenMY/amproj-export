// 首次设备登记在浏览器中继续时，始终沿用当前页面的同一请求。
function renderUdidHandoff(token, completed, environment = { document, navigator }) {
  const doc = environment.document;
  let panel = doc.getElementById('udid-safari-handoff');
  if (completed || !/^[a-f0-9]{48}$/.test(token || '')) {
    if (panel) panel.remove();
    return;
  }
  const notice = doc.getElementById('action-notice');
  if (!notice) return;
  const url = 'https://am.ayakameow.cn/udid/mobileconfig/' + token;
  if (panel) {
    const input = panel.querySelector('input');
    if (input.value !== url) input.value = url;
    return;
  }
  panel = doc.createElement('div');
  panel.id = 'udid-safari-handoff';
  panel.className = 'simple-notice';
  const help = doc.createElement('p');
  help.textContent = '没看到描述文件？复制下面的登记链接，用 Safari 打开。完成设置中的安装后，返回当前页面继续。';
  const input = doc.createElement('input');
  input.type = 'text'; input.readOnly = true; input.value = url;
  input.setAttribute('aria-label', '当前设备登记链接');
  input.style.width = '100%';
  const button = doc.createElement('button');
  button.type = 'button'; button.className = 'simple-button simple-button-outline';
  button.textContent = '复制登记链接';
  button.addEventListener('click', async () => {
    let copied = false;
    try {
      if (environment.navigator.clipboard?.writeText) {
        await environment.navigator.clipboard.writeText(input.value);
        copied = true;
      }
    } catch (_) { /* 内置浏览器可能限制剪贴板，下面保留手动复制入口。 */ }
    if (!copied) {
      input.focus(); input.select();
      try { copied = doc.execCommand('copy') === true; } catch (_) {}
    }
    button.textContent = copied ? '已复制，请在 Safari 中粘贴打开' : '请长按上方链接，选择复制';
  });
  panel.append(help, input, button);
  notice.insertAdjacentElement('afterend', panel);
}
if (typeof module !== 'undefined') module.exports = { renderUdidHandoff };
