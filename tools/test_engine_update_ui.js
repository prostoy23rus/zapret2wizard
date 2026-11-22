#!/usr/bin/env node
'use strict';
// Exercise the actual LuCI post-update migration without a browser/network/router.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const file = path.join(__dirname, '../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js');
const source = fs.readFileSync(file, 'utf8');
const start = source.indexOf('		function finishRuntimeUpdate() {');
const end = source.indexOf("\n\t\ttry {\n\t\t\tif (localStorage.getItem('bcw_just_updated')", start);
assert(start > 0 && end > start, 'actual migration function boundary missing');
const migration = source.slice(start, end);
async function scenario(name, responses, expected, completed) {
  const calls = [], notifications = [], timers = [], storage = {bcw_just_updated:'1'};
  const context = {
    HELPER_BIN: '/usr/bin/blockcheckw-helper',
    E: (_tag, _attrs, text) => text,
    parseHelperJson: res => JSON.parse(res.stdout),
    ui: {addNotification: (_node, text, kind) => notifications.push({text, kind})},
    localStorage: {removeItem: key => delete storage[key]},
    setTimeout: fn => timers.push(fn),
    fs: {exec: (_bin, args) => {
      calls.push(args[0]);
      const value = responses.shift();
      if (value instanceof Error) return Promise.reject(value);
      assert(value, 'unexpected extra RPC: ' + args[0]);
      return Promise.resolve({stdout: JSON.stringify(value)});
    }}
  };
  vm.runInNewContext(migration + '\nfinishRuntimeUpdate();', context);
  for (let i=0; i<30; i++) {
    await Promise.resolve(); await Promise.resolve();
    const fn = timers.shift();
    if (fn) fn();
    else if (responses.length === 0) break;
  }
  await Promise.resolve(); await Promise.resolve();
  assert(notifications.some(n => n.text.includes(expected)), name + ': expected notification ' + expected);
  assert.equal(!storage.bcw_just_updated, completed, name + ': completion marker');
  assert.equal(calls[0], 'engine_repair_bg', name + ': new helper must repair old update automatically');
  console.log('PASS:', name);
}
(async () => {
  await scenario('old helper update continues with new worker', [{success:true}, {state:'running'}, {state:'done',success:true}], 'Обновление проверено', true);
  await scenario('failed engine upgrade never claims success', [{success:true}, {state:'error',error:'NoFilterMark remains'}], 'NoFilterMark remains', true);
  await scenario('worker refusal surfaced, not stale done', [{success:false,error:'busy'}], 'busy', false);
  await scenario('RPC timeout still polls actual worker', [new Error('XHR timeout'), {state:'done',success:true}], 'Обновление проверено', true);
  console.log('PASS: post-update UI migration');
})().catch(e => { console.error(e); process.exitCode=1; });
