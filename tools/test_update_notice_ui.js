#!/usr/bin/env node
'use strict';
// Execute actual LuCI render/update functions; no RPC, browser or installation effects.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const src = fs.readFileSync(path.join(__dirname, '../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js'), 'utf8');
function section(start,end) { const a=src.indexOf(start), b=src.indexOf(end,a);assert(a>=0&&b>a,start);return src.slice(a,b); }
function E(tag,attrs,children) {
 const n={tag,attrs:attrs||{},style:{},children:[]};
 n.appendChild=c=>n.children.push(c);
 Object.defineProperty(n,'innerHTML',{set(){n.children=[];}});
 if(!Array.isArray(children)) children=children==null?[]:[children];
 children.forEach(c=>n.appendChild(c));return n;
}
const text=n=>typeof n==='string'?n:n&&n.children?n.children.map(text).join(''):'';
const all=n=>!n||typeof n!=='object'?[]:[n,...n.children.flatMap(all)];
function fixture(current='0.37.10') {
 const notes=[],updates=[];let modal;
 const ctx={E,curVer:current,updateBannerCard:E('div'),btnCheckUpdate:E('button'),updateCheckStatus:{},lastNoUpdateNotifyAt:0,
 document:{createTextNode:s=>s},Date,Object,Array,
 ui:{hideModal(){},addNotification(_,n,type){notes.push({text:text(n),type});}},
 bcwShowModal(title,body,buttons){modal=E('modal',{},[title,...body,...buttons]);},doRunUpdate:v=>updates.push(v)};
 vm.createContext(ctx);
 vm.runInContext(section('function updateVersionLabel(value) {','function checkVersion() {')+section('		function confirmRunUpdate(targetVer) {','		function doCheckUpdate(isManual) {'),ctx);
 return {ctx,notes,updates,get modal(){return modal;},apply(data,manual=false){ctx.applyUpdateResult(data,manual);}};
}
const upgrade={success:true,current_version:'0.37.10',latest_version:'0.37.11',has_update:true,changelog:['example']};
let f=fixture();f.apply(upgrade);
assert.match(text(f.ctx.updateBannerCard),/Установлена: v0.37.10/);
assert.match(text(f.ctx.updateBannerCard),/Доступна: v0.37.11/);
assert.match(text(f.ctx.btnCheckUpdate),/Установлена: v0.37.10 → Доступна: v0.37.11/);
const action=all(f.ctx.updateBannerCard).find(n=>n.tag==='button'&&text(n).includes('Обновить до'));
assert(action);action.attrs.click();assert.equal(f.updates.length,0,'click must show confirmation, not install');
assert.match(text(f.modal),/Установлена: v0.37.10/);assert.match(text(f.modal),/Доступна: v0.37.11/);
all(f.modal).find(n=>n.tag==='button'&&text(n)==='Отмена').attrs.click();assert.equal(f.updates.length,0);
all(f.modal).find(n=>n.tag==='button'&&text(n).includes('Установить обновление')).attrs.click();assert.deepEqual(f.updates,['0.37.11']);
f=fixture('0.37.9');f.apply(upgrade);assert.equal(f.ctx.curVer,'0.37.10','fresh result is authoritative');
f.apply({...upgrade,current_version:'0.37.11',has_update:false},true);
assert.equal(f.ctx.updateBannerCard.style.display,'none');assert.match(text(f.ctx.btnCheckUpdate),/Установлена: v0.37.11 · Обновлений нет/);assert.match(f.notes.at(-1).text,/Доступна: v0.37.11/);
for(const bad of [null,{success:false,error:'offline'}, {...upgrade,current_version:null}, {...upgrade,current_version:' '}, {...upgrade,latest_version:null}, {...upgrade,latest_version:42}]) {
 f=fixture();f.apply(upgrade);f.apply(bad,true);
 assert.equal(f.ctx.updateCheckStatus.has_update,false);assert.equal(f.ctx.updateBannerCard.style.display,'none');
 assert(!text(f.ctx.btnCheckUpdate).includes('Обновлений нет'));assert(!text(f.ctx.btnCheckUpdate).includes('0.15.'));
 assert.equal(f.notes.at(-1).type,'warning');assert.equal(f.updates.length,0);
}
f=fixture(null);f.apply({success:false,current_version:null},true);assert.match(text(f.ctx.btnCheckUpdate),/Установлена: не определена/);
assert.equal(f.ctx.updateVersionLabel('v0.37.11'),'v0.37.11');assert.equal(f.ctx.updateVersionLabel(null),'не определена');
assert(src.includes('confirmRunUpdate(updateCheckStatus.latest_version);'), 'header opens the same confirmation');
assert(!section('function checkVersion() {','function formatBlockType').includes('0.15.'));
console.log('PASS update notice: installed/available, fresh metadata, confirmation/cancel, no-update, unknown/error reset, no invented release');
