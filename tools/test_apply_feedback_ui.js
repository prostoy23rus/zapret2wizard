'use strict';
const fs = require('fs');
const path = require('path');
const MAIN = path.resolve(__dirname, '..', 'openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js');
const mainText = fs.readFileSync(MAIN, 'utf8');
for (const marker of ['Подобрать стратегию для этих сайтов', 'Общие сайты (User)» применяется только', 'showApplyFailureModal({ applyResult: out']) {
  if (!mainText.includes(marker)) { console.log('FAIL: missing marker', marker); process.exit(1); }
}

		function applyFailureSummary(out) {
			out = out || {};
			var lines = [];
			var rolled = out.rolled_back === true;
			var title = (out.success === false)
				? 'Стратегия не применена'
				: (rolled ? 'Стратегия не подтвердилась — возвращена прежняя конфигурация'
				          : 'Стратегия записана, но трафик не подтверждён');
			if (out.success === false) {
				lines.push({ label: 'Ошибка helper', value: out.error || 'неизвестная ошибка' });
			}
			var cp = out.client_probe || {};
			var video = cp.video || {};
			var vcode = video.video_code || video.code || '';
			var vstate = video.verification_state || '';
			if (vcode || vstate || video.transfer_verified != null) {
				var vtext = vcode ? ('код ' + vcode) : 'код —';
				if (vstate) vtext += ', ' + vstate;
				if (video.transfer_verified === true) vtext += ', передача подтверждена';
				if (video.transfer_verified === false) vtext += ', передача не подтверждена';
				lines.push({ label: 'Видео-хост googlevideo', value: vtext });
				if (String(vcode) === '000') {
					lines.push({ label: 'Вероятная причина', value: 'ТСПУ рвёт видеопоток; стратегия не прошла проверку объёма. Нужна другая техника (fakeddisorder / fake+multisplit и т.п.).' });
				}
			}
			var api = cp.api || out.api || {};
			var acode = api.code || api.status || '';
			if (acode) lines.push({ label: 'API YouTube (youtubei)', value: String(acode) });
			var md = out.multi_domain || {};
			if (md.overall_status) lines.push({ label: 'Проверка доменов', value: String(md.overall_status) + (md.http_code ? ' (HTTP ' + md.http_code + ')' : '') });
			var st = out.stall_reason || video.stall_reason || '';
			if (st) lines.push({ label: 'Причина остановки', value: String(st) });
			if (rolled) lines.push({ label: 'Что сделано', value: 'Прежняя рабочая конфигурация восстановлена, служба перезапущена.' });
			if (!lines.length) lines.push({ label: 'Результат', value: 'Подробности: /tmp/bcw_apply_result.json и раздел «Диагностика».' });
			return { title: title, rolledBack: rolled, lines: lines };
		}



var s1 = applyFailureSummary({ success: true, rolled_back: true, client_probe: { video: { video_code: '000', transfer_verified: false } }, multi_domain: { overall_status: 'degraded', http_code: 200 } });
if (!/не подтвердилась/.test(s1.title) || !s1.rolledBack) { console.log('FAIL: rolled_back title', s1.title); process.exit(1); }
if (!s1.lines.some(function(l) { return l.label === 'Вероятная причина' && /ТСПУ/.test(l.value); })) { console.log('FAIL: no TSPU reason', JSON.stringify(s1.lines)); process.exit(1); }
if (!s1.lines.some(function(l) { return l.label === 'Видео-хост googlevideo'; })) { console.log('FAIL: no video line'); process.exit(1); }
if (!s1.lines.some(function(l) { return l.label === 'Проверка доменов' && /degraded/.test(l.value); })) { console.log('FAIL: no domain line'); process.exit(1); }

var s2 = applyFailureSummary({ success: false, error: 'helper exploded' });
if (!/не применена/.test(s2.title)) { console.log('FAIL: error title', s2.title); process.exit(1); }
if (!s2.lines.some(function(l) { return l.label === 'Ошибка helper' && l.value === 'helper exploded'; })) { console.log('FAIL: no helper error line'); process.exit(1); }

var s3 = applyFailureSummary({ success: true });
if (!/записана/.test(s3.title) || s3.lines.length !== 1 || !/bcw_apply_result/.test(s3.lines[0].value)) { console.log('FAIL: fallback summary', JSON.stringify(s3)); process.exit(1); }
console.log('OK: apply failure summary + hostlist CTA markers');
