'use strict';
// Execute exact production speed metric expressions, without loading LuCI or any network.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js'), 'utf8');
const start = source.indexOf('var speedVal = parsed.speed_known');
assert(start >= 0, 'production knownness rendering anchor');
const end = source.indexOf('var modalBody = [', start);
assert(end > start, 'production metric block end');
const block = source.slice(start, end);
function render(parsed) {
    const context = { parsed };
    vm.runInNewContext(block, context);
    return context;
}
const unknown = render({speed_known:false,bytes_known:false,elapsed_known:false,connect_known:false,
    speed_kbs:0,speed_mbs:0,speed_mbps:0,size_mb:'0.00',total_time_sec:'0.00',latency_ms:0});
assert.strictEqual(unknown.speedVal, 'Не измерено');
assert.strictEqual(unknown.speedMbps, '');
assert.strictEqual(unknown.connectText, 'Не измерено');
assert.strictEqual(unknown.volumeText, 'Объём не измерен / время не измерено');
const zero = render({speed_known:true,bytes_known:true,elapsed_known:true,connect_known:true,
    speed_kbs:0,speed_mbs:0,speed_mbps:0,size_mb:'0.00',total_time_sec:'0.00',latency_ms:0});
assert.strictEqual(zero.speedVal, '0 КБ/с');
assert.strictEqual(zero.speedMbps, '0 Мбит/с');
assert.strictEqual(zero.connectText, '0 мс');
assert.strictEqual(zero.volumeText, '0.00 МБ / 0.00с');
const measured = render({speed_known:true,bytes_known:true,elapsed_known:true,connect_known:true,
    speed_kbs:100,speed_mbs:0.1,speed_mbps:0.8,size_mb:'1.40',total_time_sec:'8.00',latency_ms:50});
assert.strictEqual(measured.speedVal,'0.1 МБ/с');
assert.strictEqual(measured.connectText,'50 мс');
assert.strictEqual(measured.volumeText,'1.40 МБ / 8.00с');
console.log('transfer UI: 11 production-expression assertions passed');
