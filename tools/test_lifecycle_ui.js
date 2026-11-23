#!/usr/bin/env node
'use strict';
// Evaluate actual LuCI lifecycle consumers; no DOM/browser/network/router.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js'), 'utf8');
const start = source.indexOf('		function doUninstallService() {');
const end = source.indexOf('\n\t\t// Старый updater', start);
const removal = source.slice(start, end);
assert(start > 0 && end > start);
async function scenario(name, ack, states, success, expected) {
  const modals = [], notices = [], timers = [];
  let redirects = 0;
  const context = {
    HELPER_BIN: '/usr/bin/blockcheckw-helper',
    E: (_t, _a, text) => text,
    L: {url: x => x},
    window: {location: {set href(_x) { redirects++; }}},
    ui: {hideModal() {}, addNotification: (_n, text) => notices.push(text)},
    bcwShowModal: (title, body) => modals.push({title, body}),
    parseHelperJson: res => JSON.parse(res.stdout),
    setTimeout: fn => timers.push(fn),
    fs: {exec: () => Promise.resolve({stdout: JSON.stringify(ack)}), read: () => {
      const state = states.shift();
      if (state instanceof Error) return Promise.reject(state);
      assert(state, 'unexpected read');
      return Promise.resolve(typeof state === 'string' ? state : JSON.stringify(state));
    }}
  };
  vm.runInNewContext(removal + '\ndoUninstallService();', context);
  for (let i = 0; i < 100; i++) {
    await Promise.resolve(); await Promise.resolve();
    const fn = timers.shift(); if (fn) fn();
  }
  assert.equal(modals.some(x => x.title === 'Удаление завершено'), success, name);
  assert.equal(redirects > 0, success, name + ': redirect');
  if (expected) assert(notices.some(x => x.includes(expected)), name + ': error ' + notices);
  console.log('PASS:', name);
}
(async () => {
  const ack = {started:true, success:false, operation:'run-1'};
  await scenario('pending acknowledgement never displays success', ack, [{operation:'run-1',status:'running',success:false}, {operation:'run-1',status:'done',success:true}], true);
  await scenario('failed teardown reports terminal failure', ack, [{operation:'run-1',status:'error',success:false,error:'package still registered'}], false, 'package still registered');
  await scenario('stale terminal result cannot prove new removal', ack, [{operation:'old',status:'done',success:true}], false, 'другого удаления');
  await scenario('RPC read failure remains unconfirmed', ack, [new Error('RPC stopped')], false, 'RPC stopped');
  await scenario('worker refusal requires no status poll', {success:false,error:'scan active'}, [], false, 'scan active');
  const begin = source.indexOf('		function svcAction(action) {');
  const service = source.slice(begin, source.indexOf('\n\t\tfunction rollbackConfig()', begin));
  for (const ok of [true, false]) {
    const messages = []; let reloaded = false;
    vm.runInNewContext(service + '\nsvcAction("stop");', {
      HELPER_BIN:'/helper', fs:{exec:()=>Promise.resolve({stdout:JSON.stringify({ok,error:'failed'})})},
      parseHelperJson:res=>JSON.parse(res.stdout), E:(_t,_a,x)=>x,
      ui:{addNotification:(_n,text,kind)=>messages.push(kind)}, setTimeout:()=>{reloaded=true;}
    });
    for(let i=0;i<10;i++) await Promise.resolve();
    assert.deepEqual(messages, [ok ? 'info' : 'danger']); assert.equal(reloaded, ok);
  }
  console.log('PASS: service action success follows checked backend outcome');
})().catch(e => { console.error(e); process.exitCode = 1; });
