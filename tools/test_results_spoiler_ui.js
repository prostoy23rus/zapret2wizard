#!/usr/bin/env node
"use strict";
// Regression: switching a target/preset must not auto-open the found-strategies spoiler.
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
	throw new Error("unterminated: " + name);
}
function assert(cond, msg) { if (!cond) { console.error("FAIL: " + msg); process.exit(1); } }
const select = extractFunction("selectTarget");
assert(select.includes("isStrategiesExpanded = false"), "selectTarget must collapse the spoiler");
assert(select.includes("updateSpoilerUI()"), "selectTarget must refresh spoiler UI");
const load = extractFunction("loadResultsForTarget");
assert(load.includes("isStrategiesExpanded = false"), "empty results must stay collapsed");
assert(!load.includes("isStrategiesExpanded = true"), "empty results must not auto-expand");
console.log("OK: found-strategies spoiler stays collapsed on preset switch");
