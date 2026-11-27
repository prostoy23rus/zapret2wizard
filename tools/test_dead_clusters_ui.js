#!/usr/bin/env node
"use strict";
// Regression: status polling must update a switch without re-firing onChange.
// A toggle loop caused endless "Фильтр ... включён" notifications in 0.38.0.
const fs = require("fs");
const path = require("path");

const file = path.resolve(__dirname, "../openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js");
const src = fs.readFileSync(file, "utf8");

function extractFunction(name) {
	const start = src.indexOf("function " + name);
	if (start < 0) throw new Error("function not found: " + name);
	let depth = 0;
	for (let i = start; i < src.length; i++) {
		if (src[i] === "{") depth++;
		else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(start, i + 1); }
	}
	throw new Error("unterminated function: " + name);
}

function El(tag, attrs, children) {
	const classes = new Set();
	const el = {
		tag: tag, attrs: attrs || {}, children: children || [],
		classList: {
			toggle: function(c, on) { if (on) classes.add(c); else classes.delete(c); },
			contains: function(c) { return classes.has(c); }
		},
		setAttribute: function(k, v) { this[k] = v; }
	};
	if (attrs && attrs.class) String(attrs.class).split(/\s+/).forEach(function(c) { if (c) classes.add(c); });
	return el;
}

const make = new Function("E", extractFunction("makeToggleSwitch") + "\nreturn makeToggleSwitch;")(El);
let calls = 0;
const sw = make(false, function() { calls++; });

function assert(cond, msg) { if (!cond) { console.error("FAIL: " + msg); process.exit(1); } }

sw.setSilent(true);
assert(calls === 0, "setSilent(true) must not call onChange");
assert(sw.classList.contains("on"), "setSilent(true) must paint on");
sw.setSilent(false);
assert(calls === 0, "setSilent(false) must not call onChange");
assert(!sw.classList.contains("on"), "setSilent(false) must paint off");

sw.attrs.click({ preventDefault: function() {} });
assert(calls === 1, "real click must call onChange once");
assert(sw.classList.contains("on"), "click must turn on");
sw.setSilent(false);
assert(calls === 1, "status resync after click must stay silent");

assert(src.includes("sw.setSilent(!!st.enabled)"), "dead-cluster render must use setSilent");
assert(src.includes("sw.setSilent(!v)"), "toggle rollback must use setSilent");
console.log("OK: dead clusters UI silent toggle regression");
