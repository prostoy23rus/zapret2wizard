'use strict';
const state = { notifications: [], reset: 0, started: 0, startedArg: null, phase: '', text: '', width: '' };
function E(tag, attrs, children) { return { tag: tag, attrs: attrs || {}, children: children }; }
var HELPER_BIN = '/usr/bin/blockcheckw-helper';
function parseHelperJson(res) { try { return JSON.parse(String(res && res.stdout || '{}')); } catch (e) { return null; } }
var progressPhaseEl = { style: {}, set textContent(v) { state.phase = v; } };
var progressTextEl = { set textContent(v) { state.text = v; } };
var progressBarEl = { style: {} };
var progressPercentEl = { set textContent(v) { state.width = v; } };
function resetScanUI() { state.reset++; }
function startScan(retried) { state.started++; state.startedArg = retried; }
var ui = { addNotification: function(a, el, type) { state.notifications.push({ text: el && el.children, type: type }); } };
var calls = 0;
var fs = { exec: function(bin, args) {
  if (args[0] === 'engine_repair_status') {
    calls++;
    if (state.mode === 'error') return Promise.resolve({ stdout: JSON.stringify({ state: 'error', error: 'network offline' }) });
    if (calls < 2) return Promise.resolve({ stdout: JSON.stringify({ state: 'running' }) });
    return Promise.resolve({ stdout: JSON.stringify({ state: 'done' }) });
  }
  return Promise.resolve({ stdout: '{}' });
} };
function sleep(ms) { return new Promise(function(r) { setTimeout(r, ms); }); }

		// issue #6: несовместимый/чужой nfqws2 больше не тупик. Helper сам
		// запускает восстановление движка, а UI ждёт его и повторяет подбор.
		function waitEngineRepairThenRetry(allowRetry) {
			var tries = 0;
			progressPhaseEl.textContent = 'Восстанавливаю совместимый движок nfqws2…';
			progressPhaseEl.style.color = '#e5c07b';
			progressTextEl.textContent = 'Текущий движок несовместим с прошивкой или обновлением. Идёт автоматическое восстановление — обычно 1–2 минуты, ничего нажимать не нужно.';
			progressBarEl.style.width = '15%';
			progressPercentEl.textContent = '15%';
			function finishWithError(text) {
				resetScanUI();
				ui.addNotification(null, E('p', {}, text), 'danger');
			}
			function poll() {
				fs.exec(HELPER_BIN, ['engine_repair_status']).then(function(res) {
					var st = parseHelperJson(res) || {};
					if (st.state === 'done') {
						ui.addNotification(null, E('p', {}, '✓ Движок восстановлен — запускаю подбор заново'), 'info');
						if (allowRetry !== false) { startScan(true); } else { resetScanUI(); }
						return;
					}
					if (st.state === 'error') {
						finishWithError('Не удалось восстановить движок: ' + (st.error || st.message || 'неизвестная ошибка') + '. Выполните blockcheckw-helper engine_repair по SSH или откройте Диагностика → журнал проверки.');
						return;
					}
					if (++tries < 90) { setTimeout(poll, 2000); return; }
					finishWithError('Восстановление движка не завершилось за 3 минуты. Проверьте /tmp/bcw_engine_repair.log и повторите поиск.');
				}).catch(function() {
					if (++tries < 90) { setTimeout(poll, 2000); return; }
					finishWithError('Не удалось получить статус восстановления движка. Проверьте службу и повторите поиск.');
				});
			}
			poll();
		}



(async function() {
  state.mode = 'done';
  waitEngineRepairThenRetry(true);
  await sleep(2600);
  if (state.started !== 1 || state.startedArg !== true) { console.log('FAIL: retry not started once', state.started, state.startedArg); process.exit(1); }
  if (!state.notifications.some(function(n) { return /Движок восстановлен/.test(String(n.text)); })) { console.log('FAIL: no success notification', JSON.stringify(state.notifications)); process.exit(1); }
  if (!/Восстанавливаю совместимый движок/.test(state.phase)) { console.log('FAIL: progress phase missing'); process.exit(1); }
  // error path
  state.mode = 'error'; state.notifications = []; state.reset = 0; calls = 0;
  waitEngineRepairThenRetry(false);
  await sleep(2600);
  if (state.reset !== 1) { console.log('FAIL: resetScanUI not called on error', state.reset); process.exit(1); }
  var n = state.notifications[0];
  if (!n || n.type !== 'danger' || !/Не удалось восстановить движок/.test(String(n.text))) { console.log('FAIL: error notification', JSON.stringify(state.notifications)); process.exit(1); }
  console.log('OK: engine repair UI retry/error flow');
})().catch(function(e) { console.log('FAIL:', e && e.stack || e); process.exit(1); });
