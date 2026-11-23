/* Actual modal function in VM; no browser, RPC, router, or service effects. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js'), 'utf8');
const start = source.indexOf('function showHostlistsModal(hostlists) {');
const end = source.indexOf('\n\t\tfunction confirmUninstall()', start);
assert(start >= 0 && end > start);
function E(tag, attrs, children) {
  const node = { tag, attrs: attrs || {}, style: {}, children: [], value: '', disabled: false, textContent: '' };
  const style = (node.attrs.style || '').match(/display:\s*([^;]+)/);
  if (style) node.style.display = style[1];
  node.appendChild = child => node.children.push(child);
  Object.defineProperty(node, 'innerHTML', { set() { node.children = []; } });
  if (!Array.isArray(children)) children = children == null ? [] : [children];
  children.forEach(child => node.children.push(child));
  return node;
}
const nodes = n => (!n || typeof n !== 'object') ? [] : [n, ...n.children.flatMap(nodes)];
const text = n => typeof n === 'string' ? n : n.textContent + n.children.map(text).join(' ');
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(hl, responses = {}) {
  const notes = [], calls = [];
  let modal;
  const info = { hostlists: [hl], services: { builtin: { section: 'BlockcheckW_General', script: 'test', enabled: false } } };
  const ctx = { E, Array, String, zapretInfo: info, HELPER_BIN: 'fixture-helper',
    parseHelperJson: res => { try { return JSON.parse(res.stdout); } catch (_) { return null; } },
    getZapretInfo: () => Promise.resolve(info), updateSummaryBox() {},
    bcwShowModal(title, body, buttons) { modal = E('modal', {}, body.concat(buttons)); },
    ui: { hideModal() {}, addNotification(_, body, type) { notes.push({ text: text(body), type }); } },
    fs: { exec(_, args) { calls.push(args); const value = responses[args[0]]; return Promise.resolve({ code: 0, stdout: JSON.stringify(value) }); } }
  };
  vm.createContext(ctx); vm.runInContext(source.slice(start,end),ctx);ctx.showHostlistsModal([hl]);
  return { get modal() { return modal; }, calls, notes,
    find(tag, needle) { return nodes(modal).find(n => n.tag === tag && text(n).includes(needle)); },
    click(tag, needle) { const n = this.find(tag,needle);assert(n,needle);n.attrs.click.call(n);return n; }
  };
}
const hl = { key: 'user', name: 'User', file: 'fixture', exists: true, domains_count: 33, uci_configured: true, attached: true, enabled: false, service_running: true };
(async () => {
  for (const [patch, expected] of [ [{enabled:false}, 'стратегия выключена'], [{attached:false}, 'не привязан'], [{service_running:false,enabled:true}, 'не запущена'], [{exists:false}, 'отсутствует'], [{enabled:true,domains_count:0}, 'Список пуст'], [{enabled:true}, 'Обработка конкретного домена не проверена'] ]) {
    const f = fixture(Object.assign({},hl,patch));
    assert(text(f.modal).includes(expected), expected);
    const warning = nodes(f.modal).find(n => n.attrs.role === 'status' && text(n).includes(expected));
    assert(warning); assert.notEqual(warning.style.display, 'none');assert.equal(f.calls.length,0);
  }
  for (const [result, type, needle] of [
    [{success:false,saved:false,error:'save_failed'}, null, 'Список не сохранён'],
    [{success:false,saved:true,error:'saved_but_restart_failed',revision:'2-2',restart:'failed'}, 'warning','Список сохранён, но'],
    [{success:true,saved:true,revision:'2-2',restart_verified:true,written:0,skipped:0,count:0}, 'info','готовность службы подтверждена'],
    [{success:true},null,'Список не сохранён']
  ]) {
    const f = fixture(hl,{read_hostlist:{success:true,domains:['old.example'],count:1,revision:'1-1'},write_hostlist:result});
    f.click('button','Изменить');await tick();
    assert(text(f.modal).includes('стратегия выключена'), 'warning survives read');
    const area=f.find('textarea','');area.value='';
    const save=f.click('button','Сохранить');await tick();await tick();
    assert.equal(save.disabled,false);assert(text(f.modal).includes(needle)||f.notes.some(n=>n.text.includes(needle)),needle);
    const call=f.calls.find(c=>c[0]==='write_hostlist');assert.deepEqual(Array.from(call),['write_hostlist','user','--revision','1-1','--empty']);
    assert.equal(f.notes.filter(n=>n.type==='info').length,type==='info'?1:0);
    if(type)assert(f.notes.some(n=>n.type===type));
  }
  const refresh=fixture(hl,{ensure_hostlists:{error:'fail'}});refresh.click('button','Проверить и восстановить');await tick();await tick();assert(refresh.notes.some(n=>n.type==='danger'));assert(!refresh.notes.some(n=>n.type==='info'));
  console.log('PASS actual hostlist modal VM: six states, read warning, four save outcomes, empty/revision args, refresh rejection');
})().catch(e=>{console.error(e);process.exitCode=1;});
