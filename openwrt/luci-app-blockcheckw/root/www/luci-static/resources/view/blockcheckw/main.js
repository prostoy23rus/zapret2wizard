'use strict';
'require view';
'require fs';
'require ui';

var HELPER_BIN = '/usr/bin/blockcheckw-helper';
var isRunning = false;
var pollInterval = null;
var logPollInterval = null;
var currentTarget = 'preset_youtube';
var currentMode = 'smart';
var doCircular = true;
var autoApply = true;
var activeScanInProgress = false;
var activeLogTab = 'scanner';
var autoLogScroll = true;
var lastResults = [];
var lastCircular = '';
var zapretServicesData = {};
var zapretAllStrategies = [];

var PRESET_DEFS = {
	'builtin': {
		name: 'Встроенные хосты (33)',
		label: 'Встроенные хосты (33)',
		icon: '🌐',
		domain: 'rutracker.org',
		domainsText: '33 хоста, 17 провайдеров (Rutracker, Pornhub, TorProject, BBC и др.)',
		test_url: 'https://rutracker.org',
		key: 'builtin',
		port: '80,443',
		hint: {
			title: 'Встроенные хосты (33 сайта, 17 провайдеров)',
			summary: 'Комплексный профиль для обхода блокировок Рунета по широкому спектру популярных заблокированных ресурсов.',
			details: [
				{ title: '🎯 Что тестируется', text: '33 домена заблокированных ресурсов (Rutracker, Pornhub, TorProject, BBC, Meduza, LinkedIn, Soundcloud и др.) на портах 80 (HTTP) и 443 (HTTPS).' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_General (список list_hosts_general). Защищает весь общий заблокированный веб-трафик домашней сети.' },
				{ title: '💡 Универсальность', text: 'Подобранная стратегия находит «золотую середину» против алгоритмов ТСПУ вашего интернет-провайдера, открывая сразу сотни сайтов.' }
			]
		}
	},
	'preset_youtube': {
		name: 'Предустановленный список YouTube (3)',
		label: 'YouTube (3)',
		icon: '📺',
		domain: 'www.youtube.com',
		domainsText: 'googlevideo.com (CDN), i.ytimg.com (превью), youtube.com, manifest.googlevideo.com',
		test_url: 'https://www.youtube.com',
		key: 'preset_youtube',
		port: '443',
		hint: {
			title: 'YouTube (видеопотоки, превью, веб-плеер)',
			summary: 'Специализированный режим для полного обхода троттлинга (замедления) и блокировки YouTube на смартфонах, Smart TV и ПК.',
			details: [
				{ title: '🎯 Что тестируется', text: 'googlevideo.com (CDN видеопотоков 1080p-4K), i.ytimg.com (обложки и аватары), youtube.com (веб-интерфейс и API).' },
				{ title: '🛡️ Секция Zapret2', text: 'Создает или дополняет секцию zapret2.BlockcheckW_YouTube (список list_hosts_youtube). При нахождении новой стратегии создается отдельная версия (BlockcheckW_YouTube_2...) без затирания старой.' },
				{ title: '📱 Смартфоны и Smart TV', text: 'Приложения YouTube на смартфонах и ТВ по умолчанию используют протокол QUIC (UDP 443). Роутер автоматически отклоняет QUIC мгновенным ICMP Unreachable (правило Reject-QUIC: target=REJECT), предотвращая 6–10 секундную задержку черного экрана и переводя плеер на защищенный TCP TLS.' },
				{ title: '🌐 Google Global Cache (GGC)', text: 'YouTube направляет видеопоток на локальные кеширующие сервера провайдеров (GGC). Замер скорости автоматически определяет узел, оператора и город. При зависании видео на 19–25 сек (Cache Miss) Zapret2 с Circular-связкой защищает обходные каналы к центральным ЦОД.' },
				{ title: '⚙️ Рекомендация', text: 'Используйте связку «Турбо» + «Circular авто-ротация». Circular объединит fake-split и disorder для надежной работы без буферизации.' }
			]
		}
	},
	'preset_discord': {
		name: 'Предустановленный список Discord (3)',
		label: 'Discord (3)',
		icon: '💬',
		domain: 'discord.com',
		domainsText: 'discord.com, gateway.discord.gg (голос), cdn.discordapp.com (медиа), stable.dl2.discordapp.net',
		test_url: 'https://discord.com',
		key: 'preset_discord',
		port: '443',
		hint: {
			title: 'Discord (голосовые каналы, шлюзы, текст и медиа)',
			summary: 'Профиль для восстановления работы Discord: устранение бесконечного подключения RTC («Подключение к голосовому каналу...») и загрузки картинок.',
			details: [
				{ title: '🎯 Что тестируется', text: 'gateway.discord.gg (сигнальный сервер голоса и вебсокетов), discord.com (авторизация/API), cdn.discordapp.com (медиафайлы, аватарки, вложения).' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_Discord (список list_hosts_discord). Использует L7 фильтрацию пакетов tls discord.' },
				{ title: '💡 Особенность работы', text: 'DPI провайдеров глушит первый TLS ClientHello при установлении голосового RTC соединения. Стратегия расщепляет SNI gateway.discord.gg.' }
			]
		}
	},
	'preset_twitch': {
		name: 'Предустановленный список Twitch (3)',
		label: 'Twitch (3)',
		icon: '🎮',
		domain: 'twitch.tv',
		domainsText: 'twitch.tv, static-cdn.jtvnw.net, usher.ttvnw.net (стримы)',
		test_url: 'https://twitch.tv',
		key: 'preset_twitch',
		port: '443',
		hint: {
			title: 'Twitch (прямые трансляции, стримы 1080p60 и чат)',
			summary: 'Оптимизирован для обхода замедления прямых эфиров Twitch, предотвращения постоянной буферизации и зависания плеера.',
			details: [
				{ title: '🎯 Что тестируется', text: 'twitch.tv (портал), static-cdn.jtvnw.net (стили, скрипты, смайлы), usher.ttvnw.net (видео-плейлисты HLS и сегменты трансляций).' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_Twitch (список list_hosts_twitch).' },
				{ title: '⚡ Рекомендация', text: 'Для стабильного стриминга без фризов рекомендуется использовать Circular авто-ротацию со сплитом в начале SNI (pos=1 или pos=midsld).' }
			]
		}
	},
	'preset_x': {
		name: 'Предустановленный список X (3)',
		label: 'X / Twitter (3)',
		icon: '🐦',
		domain: 'x.com',
		domainsText: 'x.com, api.x.com, pbs.twimg.com (медиа)',
		test_url: 'https://x.com',
		key: 'preset_x',
		port: '443',
		hint: {
			title: 'X / Twitter (лента твитов, медиа и авторизация)',
			summary: 'Профиль для восстановления доступа к X (бывший Twitter) в браузере и официальном мобильном приложении на смартфонах.',
			details: [
				{ title: '🎯 Что тестируется', text: 'x.com (веб-версия), api.x.com (API синхронизации ленты и авторизации), pbs.twimg.com (хостинг фото и видео).' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_X (список list_hosts_x).' },
				{ title: '💡 Особенность', text: 'Серверы X строго проверяют целостность TLS ClientHello — наилучшие результаты показывают стратегии fake-split и multisplit.' }
			]
		}
	},
	'preset_instagram': {
		name: 'Предустановленный список Instagram (2)',
		label: 'Instagram (2)',
		icon: '📸',
		domain: 'gateway.instagram.com',
		domainsText: 'gateway.instagram.com, static.cdninstagram.com',
		test_url: 'https://gateway.instagram.com',
		key: 'preset_instagram',
		port: '443',
		hint: {
			title: 'Instagram (лента, Stories, Reels и Direct)',
			summary: 'Разблокировка Instagram: быстрая загрузка контента в ленте, публикация и просмотр историй и личных сообщений.',
			details: [
				{ title: '🎯 Что тестируется', text: 'gateway.instagram.com (мобильные API-шлюзы Meta), static.cdninstagram.com (CDN медиа-файлов).' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_Instagram (список list_hosts_instagram).' },
				{ title: '📱 Совет по смартфонам', text: 'Для работы приложения убедитесь, что в телефоне в настройках сети выключен «Частный DNS-сервер» провайдера (должен стоять «Автоматически» или IP роутера).' }
			]
		}
	},
	'tcp16': {
		name: 'Кандидаты TCP 16-20 KB (110)',
		label: 'TCP 16-20 KB (110)',
		icon: '⚡',
		domain: 'media.miele.com',
		domainsText: '110 хостов из suite.json (Miele, Roxio, GetScope и др.)',
		test_url: 'https://media.miele.com',
		key: 'tcp16',
		port: '443',
		hint: {
			title: 'Кандидаты TCP 16-20 KB (110 хостов)',
			summary: 'Стресс-тестирование DPI провайдера на обработку длинных TLS-пакетов, больших окон TCP и тяжелых цепочек сертификатов.',
			details: [
				{ title: '🎯 Что тестируется', text: '110 международных хостов из набора suite.json (media.miele.com, Roxio, GetScope и др.) с размером TLS-рукопожатия более 16 КБ.' },
				{ title: '🛡️ Секция Zapret2', text: 'Запись zapret2.BlockcheckW_TCP16.' },
				{ title: '🔬 Когда полезно', text: 'Используйте, если некоторые тяжелые зарубежные сайты или платежные шлюзы с длинными сертификатами зависают при загрузке.' }
			]
		}
	},
	'domains': {
		name: 'Свои домены',
		label: 'Свои домены',
		icon: '🎯',
		domain: 'rutracker.org',
		domainsText: 'Пользовательский список доменов для поиска обхода',
		test_url: 'https://rutracker.org',
		key: 'domains',
		port: '80,443',
		hint: {
			title: 'Свои домены (Пользовательский список)',
			summary: 'Индивидуальный подбор стратегии обхода для любых конкретных сайтов, указанных вами вручную.',
			details: [
				{ title: '📝 Как использовать', text: 'Введите один или несколько доменов через пробел в поле ввода выше (например: notion.so rutracker.org canva.com).' },
				{ title: '🛡️ Секция Zapret2', text: 'Создает персональную стратегию zapret2.BlockcheckW_Custom. Правила Zapret2 будут применены точечно только к введенным адресам.' },
				{ title: '💡 Формат ввода', text: 'Указывайте только чистые имена доменов без протокола https://, портов или слэшей страниц.' }
			]
		}
	},
	'test_strategy': {
		name: 'Тест стратегии',
		label: 'Тест стратегии',
		icon: '🧪',
		domain: 'rutracker.org',
		domainsText: 'Проверка работы существующей стратегии Zapret2 на ресурсе',
		test_url: 'https://rutracker.org',
		key: 'test_strategy',
		port: '443',
		hint: {
			title: 'Тест стратегии (Проверка без сканирования)',
			summary: 'Экспресс-диагностика: проверка доступности любого ресурса через уже сохраненную на роутере конфигурацию Zapret2.',
			details: [
				{ title: '⚡ Как работает', text: 'Роутер отправляет реальный HTTP/HTTPS запрос (curl) с эмуляцией TLS ClientHello браузера и выводит точный код ответа (200 OK, 302 Redirect) и время отклика.' },
				{ title: '🔍 Выбор адреса', text: 'Адрес автоматически подставляется под выбранную стратегию (для YouTube — googlevideo.com, для Discord — gateway.discord.gg), либо вы можете указать любой свой URL.' },
				{ title: '🚀 Кнопки управления', text: 'Нажмите [ 🌐 Проверить доступность ] для моментальной проверки. Кнопку [ ⚡ Запустить поиск ] нажимайте только если хотите заново подобрать стратегию с нуля.' }
			]
		}
	}
};

function checkHelperStatus() {
	return fs.exec(HELPER_BIN, ['status']).then(function(res) {
		if (res && res.code === 0 && res.stdout) {
			try {
				return JSON.parse(res.stdout);
			} catch (e) {}
		}
		return { status: 'idle', percent: 0, phase: 'Готов к работе', strategies: [] };
	}).catch(function() {
		return { status: 'idle', percent: 0, phase: 'Готов к работе', strategies: [] };
	});
}

function getZapretInfo() {
	return fs.exec(HELPER_BIN, ['info']).then(function(res) {
		if (res && res.code === 0 && res.stdout) {
			try {
				return JSON.parse(res.stdout);
			} catch (e) {}
		}
		return { zapret2_running: 'unknown', services: {}, all_strategies: [] };
	}).catch(function() {
		return { zapret2_running: 'unknown', services: {}, all_strategies: [] };
	});
}

function getLogs() {
	return fs.exec(HELPER_BIN, ['logs']).then(function(res) {
		if (res && res.code === 0 && res.stdout) {
			try {
				return JSON.parse(res.stdout);
			} catch (e) {}
		}
		return { scanner_log: '', zapret2_log: '', daemons: '' };
	}).catch(function() {
		return { scanner_log: '', zapret2_log: '', daemons: '' };
	});
}

function checkVersion() {
	return fs.exec(HELPER_BIN, ['check_update']).then(function(res) {
		if (res && res.code === 0 && res.stdout) {
			try {
				return JSON.parse(res.stdout);
			} catch (e) {}
		}
		return { success: false, current_version: '0.15.5', has_update: false };
	}).catch(function() {
		return { success: false, current_version: '0.15.5', has_update: false };
	});
}

function formatBlockType(bType) {
	if (!bType || bType.trim() === '') return 'Определение...';
	switch (bType) {
		case 'sni_blocked':
			return '🛡️ SNI blocked (DPI блокировка по SNI — обходится Zapret2)';
		case 'throttled':
			return '⚠️ DPI Throttling (Искусственное замедление скорости до 16-20 KB)';
		case 'not_blocked':
			return '✅ Доступен без обхода (не блокируется на вашей линии)';
		case 'ip_blocked':
			return '❌ IP blocked (блокировка адреса / дроп SYN — требуется VPN)';
		case 'syn_blocked':
			return '❌ SYN blocked (пакеты глушатся у провайдера, но хост жив)';
		case 'dns_failed':
			return '⚠️ DNS Failed (ошибка разрешения имени / отравление DNS)';
		case 'host_dead':
			return '💀 Хост недоступен / выключен';
		default:
			return bType;
	}
}

function initModalBackdropHandler() {
	var overlay = document.getElementById('modal_overlay');
	if (overlay) {
		overlay.style.cursor = 'pointer';

		if (!overlay._bcw_click_bound) {
			overlay._bcw_click_bound = true;
			overlay.addEventListener('click', function(e) {
				if (e.target === overlay) {
					ui.hideModal();
				}
			});
		}

		if (!overlay._bcw_observer_bound && window.MutationObserver) {
			overlay._bcw_observer_bound = true;
			var observer = new MutationObserver(function() {
				if (!document.body.classList.contains('modal-overlay-active')) return;
				var modal = overlay.querySelector('.modal');
				if (!modal) return;
				var h4 = modal.querySelector('h4');
				if (!h4 || h4.querySelector('.bcw-modal-close-btn')) return;

				var closeBtn = E('button', {
					class: 'bcw-modal-close-btn',
					type: 'button',
					title: 'Закрыть окно (Esc)',
					click: function(e) {
						e.stopPropagation();
						ui.hideModal();
					}
				}, '✕');
				h4.appendChild(closeBtn);
			});
			observer.observe(overlay, { childList: true, subtree: true });
		}
	}

	if (!window._bcw_esc_bound) {
		window._bcw_esc_bound = true;
		window.addEventListener('keydown', function(e) {
			if ((e.key === 'Escape' || e.keyCode === 27) && document.body.classList.contains('modal-overlay-active')) {
				ui.hideModal();
			}
		});
	}
}

function bcwShowModal(titleText, bodyNodes, actions) {
	initModalBackdropHandler();

	var closeBtn = E('button', {
		class: 'bcw-modal-close-btn',
		type: 'button',
		title: 'Закрыть окно (Esc)',
		click: function(e) {
			e.stopPropagation();
			ui.hideModal();
		}
	}, '✕');

	var titleEl = E('div', {
		style: 'display: flex; align-items: center; justify-content: space-between; width: 100%; gap: 10px;'
	}, [
		(typeof titleText === 'string') ? E('span', { style: 'font-weight: bold; font-size: 15px; color: var(--bcw-text-title);' }, titleText) : titleText,
		closeBtn
	]);

	var allChildren = Array.isArray(bodyNodes) ? bodyNodes.slice() : [bodyNodes];
	if (actions && actions.length > 0) {
		allChildren.push(E('div', { class: 'right', style: 'margin-top: 16px; display: flex; gap: 8px; justify-content: flex-end;' }, actions));
	}

	var dlg = ui.showModal(titleEl, allChildren);
	return dlg;
}

return view.extend({
	load: function() {
		return Promise.all([
			checkHelperStatus(),
			getZapretInfo(),
			fs.exec(HELPER_BIN, ['ensure_hostlists']).catch(function() {})
		]);
	},

	render: function(data) {
		var statusData = data[0] || {};
		var zapretInfo = data[1] || {};
		var logsData = { scanner_log: 'Загрузка логов...', zapret2_log: 'Загрузка логов...', daemons: '' };
		var curVer = zapretInfo.version || '0.15.12';
		var versionInfo = {
			current_version: curVer,
			has_update: false,
			changelog: zapretInfo.changelog || []
		};
		zapretServicesData = zapretInfo.services || {};
		zapretAllStrategies = zapretInfo.all_strategies || [];
		var lastAppliedResult = (statusData && statusData.apply_result) ? statusData.apply_result : null;

		var container = E('div', { class: 'cbi-map bcw-wrapper' });

		// Scoped Styles & Theme System
		var styleSheet = E('style', {}, [
			'/* BlockcheckW Unified Dashboard Styles & Theme System */\n' +
			'#modal_overlay { cursor: pointer !important; }\n' +
			'#modal_overlay .modal { cursor: default !important; position: relative !important; }\n' +
			'#modal_overlay .modal > h4 { display: flex !important; align-items: center !important; justify-content: space-between !important; gap: 12px !important; width: 100% !important; box-sizing: border-box !important; }\n' +
			'.bcw-modal-close-btn { background: transparent !important; border: none !important; color: var(--bcw-text-muted) !important; font-size: 20px !important; font-weight: bold !important; line-height: 1 !important; cursor: pointer !important; padding: 4px 10px !important; border-radius: 6px !important; margin-left: auto !important; transition: all 0.15s ease !important; outline: none !important; min-width: 36px !important; min-height: 36px !important; display: inline-flex !important; align-items: center !important; justify-content: center !important; }\n' +
			'.bcw-modal-close-btn:hover { color: var(--bcw-text-title) !important; background: var(--bcw-bg-card-sub) !important; }\n' +
			'.bcw-modal-close-btn:active { background: var(--bcw-border-divider) !important; transform: scale(0.95) !important; }\n' +
			'@keyframes bcwPulseGlow { 0% { box-shadow: 0 0 0 0 rgba(0, 209, 178, 0.6); } 70% { box-shadow: 0 0 0 12px rgba(0, 209, 178, 0); } 100% { box-shadow: 0 0 0 0 rgba(0, 209, 178, 0); } }\n' +
			'.bcw-highlight-pulse { animation: bcwPulseGlow 1.2s 2 ease-out !important; border-color: #00d1b2 !important; }\n' +
			'.bcw-applied-banner { animation: bcwFadeIn 0.3s ease; }\n' +
			'@keyframes bcwFadeIn { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: translateY(0); } }\n' +
			'\n' +
			'/* Theme Variables: Default / Dark Theme */\n' +
			'.bcw-wrapper, .bcw-wrapper[data-theme="dark"], body[data-bcw-theme="dark"] {\n' +
			'  --bcw-bg-card: #20232a;\n' +
			'  --bcw-bg-card-sub: rgba(255, 255, 255, 0.03);\n' +
			'  --bcw-bg-card-inner: #252830;\n' +
			'  --bcw-border-card: #323742;\n' +
			'  --bcw-border-sub: #383e4a;\n' +
			'  --bcw-border-divider: rgba(255, 255, 255, 0.07);\n' +
			'  --bcw-text-title: #e5e9f0;\n' +
			'  --bcw-text-main: #abb2bf;\n' +
			'  --bcw-text-muted: #7f848e;\n' +
			'  --bcw-btn-bg: #282c34;\n' +
			'  --bcw-btn-color: #abb2bf;\n' +
			'  --bcw-btn-border: #485060;\n' +
			'  --bcw-btn-hover-bg: #323742;\n' +
			'  --bcw-btn-hover-color: #ffffff;\n' +
			'  --bcw-tile-bg: #252830;\n' +
			'  --bcw-tile-border: #383e4a;\n' +
			'  --bcw-tile-color: #abb2bf;\n' +
			'  --bcw-tile-hover-bg: #2d313b;\n' +
			'  --bcw-tile-active-bg: rgba(0, 209, 178, 0.12);\n' +
			'  --bcw-tile-active-color: #00d1b2;\n' +
			'  --bcw-code-bg: #181a1f;\n' +
			'  --bcw-code-color: #98c379;\n' +
			'  --bcw-code-border: #282c34;\n' +
			'  --bcw-chk-bg: #1c2027;\n' +
			'  --bcw-chk-border: #485060;\n' +
			'  --bcw-select-bg: #282c34;\n' +
			'  --bcw-select-color: #ffffff;\n' +
			'  --bcw-select-border: #485060;\n' +
			'  --bcw-hint-bg: rgba(97, 175, 239, 0.06);\n' +
			'  --bcw-hint-border: rgba(97, 175, 239, 0.22);\n' +
			'  --bcw-hint-item-bg: rgba(0, 0, 0, 0.25);\n' +
			'  --bcw-card-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);\n' +
			'}\n' +
			'\n' +
			'/* Theme Variables: Light Theme */\n' +
			'.bcw-wrapper[data-theme="light"], body[data-bcw-theme="light"] {\n' +
			'  --bcw-bg-card: #ffffff;\n' +
			'  --bcw-bg-card-sub: #f6f8fa;\n' +
			'  --bcw-bg-card-inner: #f6f8fa;\n' +
			'  --bcw-border-card: #d0d7de;\n' +
			'  --bcw-border-sub: #e1e4e8;\n' +
			'  --bcw-border-divider: rgba(0, 0, 0, 0.08);\n' +
			'  --bcw-text-title: #24292f;\n' +
			'  --bcw-text-main: #4a5568;\n' +
			'  --bcw-text-muted: #6e7781;\n' +
			'  --bcw-btn-bg: #f6f8fa;\n' +
			'  --bcw-btn-color: #24292f;\n' +
			'  --bcw-btn-border: #d0d7de;\n' +
			'  --bcw-btn-hover-bg: #eaecf0;\n' +
			'  --bcw-btn-hover-color: #0969da;\n' +
			'  --bcw-tile-bg: #ffffff;\n' +
			'  --bcw-tile-border: #d0d7de;\n' +
			'  --bcw-tile-color: #4a5568;\n' +
			'  --bcw-tile-hover-bg: #f3f6fc;\n' +
			'  --bcw-tile-active-bg: rgba(0, 180, 150, 0.12);\n' +
			'  --bcw-tile-active-color: #008775;\n' +
			'  --bcw-code-bg: #f6f8fa;\n' +
			'  --bcw-code-color: #116329;\n' +
			'  --bcw-code-border: #d0d7de;\n' +
			'  --bcw-chk-bg: #ffffff;\n' +
			'  --bcw-chk-border: #8c959f;\n' +
			'  --bcw-select-bg: #ffffff;\n' +
			'  --bcw-select-color: #24292f;\n' +
			'  --bcw-select-border: #d0d7de;\n' +
			'  --bcw-hint-bg: rgba(9, 105, 218, 0.06);\n' +
			'  --bcw-hint-border: rgba(9, 105, 218, 0.22);\n' +
			'  --bcw-hint-item-bg: #ffffff;\n' +
			'  --bcw-card-shadow: 0 1px 3px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);\n' +
			'}\n' +
			'\n' +
			'.bcw-wrapper { width: 100%; max-width: 100%; box-sizing: border-box; overflow-x: hidden; }\n' +
			'.bcw-wrapper * { box-sizing: border-box; }\n' +
			'.bcw-container { display: flex; flex-direction: column; gap: 16px; margin-top: 8px; width: 100%; max-width: 100%; overflow-x: hidden; }\n' +
			'.bcw-card { background: var(--bcw-bg-card); border: 1px solid var(--bcw-border-card); border-radius: 8px; padding: 18px 20px; box-shadow: var(--bcw-card-shadow); width: 100%; max-width: 100%; overflow-x: hidden; color: var(--bcw-text-main); transition: background 0.2s, border-color 0.2s; }\n' +
			'.bcw-card-header { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 10px; margin-bottom: 14px; padding-bottom: 10px; border-bottom: 1px solid var(--bcw-border-divider); width: 100%; }\n' +
			'.bcw-spoiler-header:hover { background: var(--bcw-bg-card-sub); border-radius: 6px; }\n' +
			'.bcw-spoiler-btn { background: var(--bcw-btn-bg) !important; color: var(--bcw-btn-color) !important; border: 1px solid var(--bcw-btn-border) !important; }\n' +
			'.bcw-spoiler-btn:hover { background: var(--bcw-btn-hover-bg) !important; color: var(--bcw-btn-hover-color) !important; border-color: #3273dc !important; }\n' +
			'.bcw-card-title { font-size: 15px; font-weight: bold; margin: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; color: var(--bcw-text-title); line-height: 1.4; word-break: break-word; }\n' +
			'.bcw-header-title { color: var(--bcw-text-title); }\n' +
			'.bcw-header-sub { color: var(--bcw-text-muted); }\n' +
			'\n' +
			'/* Header Action Elements */\n' +
			'.bcw-header-item { height: 32px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; padding: 0 12px; font-size: 12px; font-weight: 600; border-radius: 6px; box-sizing: border-box; line-height: 1; white-space: nowrap; transition: all 0.2s; border: 1px solid var(--bcw-btn-border); }\n' +
			'.bcw-header-btn { background: var(--bcw-btn-bg); color: var(--bcw-btn-color); cursor: pointer; text-decoration: none; }\n' +
			'.bcw-header-btn:hover { background: var(--bcw-btn-hover-bg); color: var(--bcw-btn-hover-color); border-color: #3273dc; }\n' +
			'.bcw-header-badge { background: var(--bcw-btn-bg); color: var(--bcw-btn-color); }\n' +
			'\n' +
			'/* Theme Selector */\n' +
			'.bcw-theme-select { appearance: none; -webkit-appearance: none; -moz-appearance: none; padding-right: 24px !important; padding-left: 10px !important; background-image: url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'8\' height=\'5\'%3E%3Cpath d=\'M0 0l4 4 4-4z\' fill=\'%23888888\'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 8px center; background-size: 8px 5px; cursor: pointer; font-weight: 600; outline: none; }\n' +
			'.bcw-theme-select option { background: var(--bcw-bg-card); color: var(--bcw-text-title); }\n' +
			'\n' +
			'/* Finder Mode Tiles Grid */\n' +
			'.bcw-tiles-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 10px; width: 100%; margin-top: 4px; }\n' +
			'.bcw-tile-btn { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 12px 6px; border-radius: 8px; background: var(--bcw-tile-bg); border: 1.5px solid var(--bcw-tile-border); color: var(--bcw-tile-color); cursor: pointer; transition: all 0.2s ease; user-select: none; text-align: center; min-height: 64px; box-sizing: border-box; }\n' +
			'.bcw-tile-btn:hover { background: var(--bcw-tile-hover-bg); border-color: #61afef; color: var(--bcw-text-title); transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.18); }\n' +
			'.bcw-tile-btn.active { background: var(--bcw-tile-active-bg); border-color: var(--bcw-tile-active-color); color: var(--bcw-tile-active-color); font-weight: bold; box-shadow: 0 0 12px rgba(0, 209, 178, 0.25); }\n' +
			'.bcw-tile-icon { font-size: 20px; line-height: 1; margin-bottom: 5px; }\n' +
			'.bcw-tile-name { font-size: 12px; line-height: 1.25; font-weight: 600; }\n' +
			'.bcw-select { box-sizing: border-box; width: 100%; max-width: 100%; min-width: 0; height: 38px; padding: 0 12px; font-size: 13px; font-weight: 600; border-radius: 6px; background: var(--bcw-select-bg); color: var(--bcw-select-color); border: 1px solid var(--bcw-select-border); outline: none; cursor: pointer; transition: all 0.2s; }\n' +
			'.bcw-select:hover, .bcw-select:focus { border-color: #3273dc; box-shadow: 0 0 8px rgba(50, 115, 220, 0.3); }\n' +
			'.bcw-target-summary { margin-top: 14px; padding: 12px 14px; border-radius: 6px; background: var(--bcw-bg-card-sub); border: 1px solid var(--bcw-border-sub); display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 10px; width: 100%; }\n' +
			'\n' +
			'/* Mode Hints Box */\n' +
			'.bcw-hint-box { margin-top: 14px; padding: 14px 16px; border-radius: 6px; background: var(--bcw-hint-bg); border: 1px solid var(--bcw-hint-border); border-left: 4px solid #61afef; display: flex; flex-direction: column; gap: 8px; font-size: 13px; line-height: 1.5; width: 100%; }\n' +
			'.bcw-hint-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-weight: bold; color: #61afef; font-size: 14px; }\n' +
			'.bcw-hint-summary { color: var(--bcw-text-title); font-size: 13px; font-weight: 500; word-break: break-word; }\n' +
			'.bcw-hint-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; margin-top: 6px; padding-top: 10px; border-top: 1px solid var(--bcw-border-divider); width: 100%; }\n' +
			'.bcw-hint-item { display: flex; flex-direction: column; justify-content: flex-start; gap: 4px; background: var(--bcw-hint-item-bg); padding: 10px 14px; border-radius: 6px; border: 1px solid var(--bcw-border-sub); height: 100%; box-sizing: border-box; width: 100%; }\n' +
			'.bcw-hint-item-title { font-weight: bold; font-size: 12px; color: #98c379; display: flex; align-items: center; gap: 6px; }\n' +
			'.bcw-hint-item-text { font-size: 12px; color: var(--bcw-text-main); line-height: 1.45; word-break: break-word; }\n' +
			'\n' +
			'/* Test Strategy Hint Callout */\n' +
			'.bcw-test-hint-box { margin-top: 10px; padding: 12px 14px; background: var(--bcw-hint-bg); border: 1px solid var(--bcw-hint-border); border-left: 4px solid #3273dc; border-radius: 6px; font-size: 13px; line-height: 1.5; color: var(--bcw-text-main); }\n' +
			'\n' +
			'/* Custom Bulletproof Checkbox (Immune to theme cascade conflicts) */\n' +
			'.bcw-chk-wrap { display: inline-flex !important; align-items: center !important; gap: 10px !important; cursor: pointer !important; user-select: none !important; position: relative !important; }\n' +
			'.bcw-chk-input { position: absolute !important; opacity: 0 !important; width: 0 !important; height: 0 !important; margin: 0 !important; pointer-events: none !important; appearance: none !important; -webkit-appearance: none !important; border: none !important; background: none !important; }\n' +
			'.bcw-chk-input::before, .bcw-chk-input::after { content: none !important; display: none !important; width: 0 !important; height: 0 !important; border: none !important; }\n' +
			'.bcw-chk-box { width: 20px !important; height: 20px !important; min-width: 20px !important; min-height: 20px !important; border-radius: 6px !important; border: 1.5px solid var(--bcw-chk-border) !important; background: var(--bcw-chk-bg) !important; display: inline-flex !important; align-items: center !important; justify-content: center !important; transition: all 0.2s ease !important; box-sizing: border-box !important; position: relative !important; }\n' +
			'.bcw-chk-wrap:hover .bcw-chk-box { border-color: #00d1b2 !important; }\n' +
			'.bcw-chk-input:checked + .bcw-chk-box { background: #00d1b2 !important; border-color: #00d1b2 !important; box-shadow: 0 0 10px rgba(0, 209, 178, 0.4) !important; }\n' +
			'.bcw-chk-input:checked + .bcw-chk-box::after { content: \"\" !important; display: block !important; width: 5px !important; height: 9px !important; border: solid #091a18 !important; border-width: 0 2.5px 2.5px 0 !important; transform: rotate(45deg) translate(-1px, -1px) !important; }\n' +
			'\n' +
			'/* Unified Actions Grid (Equal Size) */\n' +
			'.bcw-actions-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; width: 100%; margin-top: 14px; }\n' +
			'.bcw-action-btn { height: 44px; box-sizing: border-box; padding: 0 16px; font-size: 13.5px; font-weight: bold; border-radius: 8px; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 8px; transition: all 0.2s ease; line-height: 1.2; text-align: center; white-space: nowrap; border: 1px solid transparent; user-select: none; width: 100%; }\n' +
			'.bcw-action-btn-primary { background: #00d1b2; color: #081a17; border-color: #00d1b2; box-shadow: 0 2px 8px rgba(0,209,178,0.25); }\n' +
			'.bcw-action-btn-primary:hover { background: #00e6c4; box-shadow: 0 0 16px rgba(0,209,178,0.45); transform: translateY(-1px); }\n' +
			'.bcw-action-btn-stop { background: #ff3860; color: #ffffff; border-color: #ff3860; box-shadow: 0 2px 8px rgba(255,56,96,0.25); }\n' +
			'.bcw-action-btn-stop:hover { background: #ff4d73; box-shadow: 0 0 14px rgba(255,56,96,0.4); }\n' +
			'.bcw-action-btn-secondary { background: var(--bcw-btn-bg); border-color: var(--bcw-btn-border); color: var(--bcw-btn-color); }\n' +
			'.bcw-action-btn-secondary:hover { background: var(--bcw-btn-hover-bg); color: var(--bcw-btn-hover-color); border-color: #3273dc; transform: translateY(-1px); }\n' +
			'.bcw-action-btn-speed { background: var(--bcw-btn-bg); border-color: var(--bcw-btn-border); color: #61afef; }\n' +
			'.bcw-action-btn-speed:hover { background: rgba(97, 175, 239, 0.15); border-color: #61afef; color: #61afef; transform: translateY(-1px); box-shadow: 0 0 12px rgba(97, 175, 239, 0.25); }\n' +
			'.bcw-param-hint { font-size: 11.5px; opacity: 0.85; line-height: 1.45; word-break: normal; overflow-wrap: break-word; color: var(--bcw-text-muted); }\n' +
			'\n' +
			'/* Legacy / General Action Buttons */\n' +
			'.bcw-action-bar { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; padding-top: 4px; width: 100%; }\n' +
			'.bcw-btn-launch, .bcw-btn-stop, .bcw-btn-secondary { height: 44px; box-sizing: border-box; padding: 0 24px; font-size: 14px; font-weight: bold; border-radius: 6px; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 8px; transition: all 0.2s; line-height: 1; white-space: nowrap; border: 1px solid transparent; }\n' +
			'.bcw-btn-launch { background: #00d1b2; color: #000; border-color: #00d1b2; box-shadow: 0 2px 8px rgba(0,209,178,0.25); }\n' +
			'.bcw-btn-launch:hover { background: #00e6c4; box-shadow: 0 0 16px rgba(0,209,178,0.45); transform: translateY(-1px); }\n' +
			'.bcw-btn-stop { background: #ff3860; color: #fff; border-color: #ff3860; box-shadow: 0 2px 8px rgba(255,56,96,0.25); }\n' +
			'.bcw-btn-stop:hover { background: #ff4d73; box-shadow: 0 0 14px rgba(255,56,96,0.4); }\n' +
			'.bcw-btn-secondary { background: var(--bcw-btn-bg); border-color: var(--bcw-btn-border); color: var(--bcw-btn-color); }\n' +
			'.bcw-btn-secondary:hover { background: var(--bcw-btn-hover-bg); color: var(--bcw-btn-hover-color); border-color: #3273dc; }\n' +
			'\n' +
			'/* Utility Buttons */\n' +
			'.bcw-btn-sm { height: 32px; padding: 0 14px; font-size: 12px; font-weight: 600; border-radius: 6px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; box-sizing: border-box; cursor: pointer; transition: all 0.2s; white-space: nowrap; line-height: 1; }\n' +
			'\n' +
			'/* Strategy Card Item */\n' +
			'.bcw-strat-item { background: var(--bcw-bg-card-sub); border: 1px solid var(--bcw-border-sub); padding: 14px; border-radius: 6px; display: flex; flex-direction: column; gap: 8px; width: 100%; box-sizing: border-box; }\n' +
			'\n' +
			'/* Code and Console Boxes */\n' +
			'.bcw-code-box { box-sizing: border-box; background: var(--bcw-code-bg); color: var(--bcw-code-color); padding: 12px 14px; border-radius: 6px; font-size: 11.5px; font-family: "SF Mono", "Consolas", "Courier New", monospace; line-height: 1.45; white-space: pre-wrap; word-break: break-all; overflow-wrap: anywhere; margin: 0; max-height: 250px; overflow-y: auto; overflow-x: hidden; width: 100%; max-width: 100%; border: 1px solid var(--bcw-code-border); }\n' +
			'.bcw-log-tabs { display: flex; flex-wrap: wrap; gap: 8px; width: 100%; }\n' +
			'.bcw-log-tab-btn { height: 32px; padding: 0 14px; font-size: 12px; font-weight: 500; cursor: pointer; border-radius: 6px; border: 1px solid var(--bcw-btn-border); background: var(--bcw-btn-bg); color: var(--bcw-btn-color); transition: all 0.2s; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; line-height: 1; }\n' +
			'.bcw-log-tab-btn.active { background: #3273dc; color: #fff; border-color: #3273dc; font-weight: bold; }\n' +
			'.bcw-line-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 8px; width: 100%; }\n' +
			'.bcw-form-row { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin-bottom: 12px; width: 100%; }\n' +
			'.bcw-form-label { font-weight: bold; min-width: 140px; font-size: 13px; color: var(--bcw-text-main); }\n' +
			'\n' +
			'/* Light Theme Specific Fine-Tuning */\n' +
			'.bcw-wrapper[data-theme="light"] .bcw-action-btn-primary { background: #009e86; border-color: #009e86; color: #ffffff; }\n' +
			'.bcw-wrapper[data-theme="light"] .bcw-action-btn-primary:hover { background: #008775; border-color: #008775; }\n' +
			'.bcw-wrapper[data-theme="light"] .bcw-active-spoiler-arrow, .bcw-wrapper[data-theme="light"] .bcw-spoiler-arrow { color: #0969da !important; }\n' +
			'.bcw-wrapper[data-theme="light"] [style*="color: #abb2bf"], .bcw-wrapper[data-theme="light"] [style*="color:#abb2bf"] { color: var(--bcw-text-main) !important; }\n' +
			'.bcw-wrapper[data-theme="light"] [style*="color: #e5e9f0"], .bcw-wrapper[data-theme="light"] [style*="color:#e5e9f0"] { color: var(--bcw-text-title) !important; }\n' +
			'.bcw-wrapper[data-theme="light"] [style*="background: #252830"], .bcw-wrapper[data-theme="light"] [style*="background: #282c34"], .bcw-wrapper[data-theme="light"] [style*="background: rgba(255,255,255,0.03)"], .bcw-wrapper[data-theme="light"] [style*="background: rgba(0,0,0,0.25)"], .bcw-wrapper[data-theme="light"] [style*="background: rgba(0, 0, 0, 0.25)"] { background: var(--bcw-bg-card-sub) !important; border-color: var(--bcw-border-sub) !important; }\n' +
			'\n' +
			'/* Modal Theme Support */\n' +
			'body[data-bcw-theme="light"] #modal_overlay .modal { background: #ffffff !important; color: #24292f !important; border: 1px solid #d0d7de !important; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.15) !important; }\n' +
			'body[data-bcw-theme="light"] #modal_overlay .modal h4 { color: #1f2328 !important; border-bottom: 1px solid #e1e4e8 !important; }\n' +
			'body[data-bcw-theme="light"] .bcw-modal-close-btn { color: #57606a !important; }\n' +
			'body[data-bcw-theme="light"] .bcw-modal-close-btn:hover { color: #1f2328 !important; background: rgba(0, 0, 0, 0.08) !important; }\n' +
			'body[data-bcw-theme="light"] #modal_overlay [style*="color: #abb2bf"], body[data-bcw-theme="light"] #modal_overlay [style*="color:#abb2bf"] { color: #57606a !important; }\n' +
			'body[data-bcw-theme="light"] #modal_overlay [style*="color: #e5e9f0"], body[data-bcw-theme="light"] #modal_overlay [style*="color:#e5e9f0"] { color: #24292f !important; }\n' +
			'body[data-bcw-theme="light"] #modal_overlay [style*="background: #282c34"], body[data-bcw-theme="light"] #modal_overlay [style*="background: rgba(255,255,255,0.03)"] { background: #f6f8fa !important; border-color: #d0d7de !important; }\n' +
			'body[data-bcw-theme="light"] #modal_overlay [style*="background: #1c2027"] { background: #eaeef2 !important; color: #0969da !important; }\n' +
			'\n' +
			'/* Responsive Overhaul */\n' +
			'@media (max-width: 1050px) {\n' +
			'  .bcw-actions-grid { grid-template-columns: repeat(2, 1fr); }\n' +
			'}\n' +
			'@media (max-width: 600px) {\n' +
			'  .bcw-actions-grid { grid-template-columns: 1fr; }\n' +
			'  .bcw-action-bar { flex-direction: column; width: 100%; }\n' +
			'  .bcw-action-bar button { width: 100%; justify-content: center; }\n' +
			'}\n' +
			'@media (max-width: 600px) {\n' +
			'  .bcw-card { padding: 12px 14px; border-radius: 6px; }\n' +
			'  .bcw-card-header { flex-direction: column; align-items: stretch; gap: 10px; }\n' +
			'  .bcw-card-header > div:last-child { width: 100%; display: flex; flex-wrap: wrap; gap: 8px; }\n' +
			'  .bcw-card-header > div:last-child button, .bcw-card-header > div:last-child a, .bcw-card-header > div:last-child select { width: 100%; justify-content: center; }\n' +
			'  .bcw-header-title { font-size: 16px !important; }\n' +
			'  .bcw-header-sub { font-size: 11.5px !important; }\n' +
			'  .bcw-header-actions { width: 100% !important; gap: 6px !important; margin-top: 10px !important; }\n' +
			'  .bcw-header-actions .bcw-header-item { flex: 1 1 calc(50% - 6px); justify-content: center; font-size: 11px; padding: 0 6px; }\n' +
			'  .bcw-tiles-grid { grid-template-columns: repeat(auto-fill, minmax(105px, 1fr)); gap: 8px; }\n' +
			'  .bcw-tile-btn { padding: 10px 4px; min-height: 58px; }\n' +
			'  .bcw-tile-icon { font-size: 18px; }\n' +
			'  .bcw-tile-name { font-size: 11px; }\n' +
			'  .bcw-hint-box { padding: 10px 12px; }\n' +
			'  .bcw-hint-grid { grid-template-columns: 1fr; gap: 8px; }\n' +
			'  .bcw-target-summary { flex-direction: column; align-items: flex-start; gap: 8px; }\n' +
			'  .bcw-form-row { flex-direction: column; align-items: stretch; gap: 6px; }\n' +
			'  .bcw-form-label { min-width: 0; }\n' +
			'  .bcw-quick-urls { margin-left: 0 !important; }\n' +
			'  .bcw-versions-bar { flex-direction: column !important; align-items: stretch !important; gap: 8px !important; }\n' +
			'  .bcw-versions-bar select { width: 100% !important; max-width: 100% !important; }\n' +
			'  .bcw-versions-actions { display: flex !important; gap: 8px !important; width: 100% !important; }\n' +
			'  .bcw-versions-actions button { flex: 1 1 50% !important; justify-content: center !important; }\n' +
			'  .bcw-line-grid { grid-template-columns: 1fr; }\n' +
			'  .bcw-log-tab-btn { flex: 1 1 calc(33.3% - 6px); padding: 0 6px; font-size: 11px; justify-content: center; text-align: center; }\n' +
			'  .bcw-log-controls { width: 100%; justify-content: space-between; }\n' +
			'  .bcw-code-box { font-size: 11px; padding: 10px 12px; }\n' +
			'  .bcw-strat-header { flex-direction: column; align-items: stretch !important; }\n' +
			'  .bcw-strat-apply-btn { width: 100% !important; height: 36px !important; }\n' +
			'}\n'
		]);
		container.appendChild(styleSheet);

		// Layout Wrapper
		var mainLayout = E('div', { class: 'bcw-container' });
		container.appendChild(mainLayout);

		// Header Section
		var zapretBadgeEl = E('span', {
			class: 'bcw-header-item ' + ((zapretInfo.zapret2_running === 'running') ? 'badge cbi-color-green' : 'badge cbi-color-red'),
			style: 'border: none;'
		}, (zapretInfo.zapret2_running === 'running') ? '✓ Zapret2Wizard активен' : '✗ Zapret2Wizard остановлен');

		// Theme Management (Dark & Light)
		var THEME_KEY = 'bcw_theme_mode';

		var themeSelectEl = E('select', {
			class: 'bcw-header-item bcw-header-btn bcw-theme-select',
			id: 'bcw-theme-select',
			title: 'Цветовая тема оформления',
			change: function() {
				applyUserThemeChoice(this.value);
			}
		}, [
			E('option', { value: 'dark' }, '🌙 Тёмная'),
			E('option', { value: 'light' }, '☀️ Светлая')
		]);

		function updateAppliedTheme() {
			var choice = themeSelectEl.value || 'dark';
			if (choice !== 'light') choice = 'dark';

			container.setAttribute('data-theme', choice);
			try {
				document.body.setAttribute('data-bcw-theme', choice);
			} catch(e) {}
		}

		function applyUserThemeChoice(choice) {
			if (choice !== 'light') choice = 'dark';
			try {
				localStorage.setItem(THEME_KEY, choice);
			} catch(e) {}
			themeSelectEl.value = choice;
			updateAppliedTheme();
		}

		var initialTheme = 'dark';
		try {
			initialTheme = localStorage.getItem(THEME_KEY) || 'dark';
			if (initialTheme !== 'dark' && initialTheme !== 'light') {
				initialTheme = 'dark';
			}
		} catch(e) {}
		themeSelectEl.value = initialTheme;
		updateAppliedTheme();

		var btnCheckUpdate = E('button', {
			class: 'bcw-header-item bcw-header-btn',
			id: 'bcw-btn-check-update',
			title: 'Автоматическая проверка обновлений...',
			click: function() {
				if (updateCheckStatus.checked && updateCheckStatus.has_update) {
					doRunUpdate(updateCheckStatus.latest_version);
				} else {
					doCheckUpdate(true);
				}
			}
		}, [
			E('span', {}, '🔄'),
			document.createTextNode(' Проверка обновлений (v' + curVer + ')...')
		]);

		var btnFeedback = E('a', {
			class: 'bcw-header-item bcw-header-btn',
			href: 'https://github.com/prostoy23rus/zapret2wizard/issues',
			target: '_blank',
			title: 'Сообщить об ошибке или предложить улучшение на GitHub'
		}, [
			E('span', {}, '💬'),
			'Баг-репорты / Идеи'
		]);

		var btnUninstall = E('button', {
			class: 'bcw-header-item bcw-header-btn',
			style: 'color: #e06c75;',
			title: 'Полностью удалить Zapret2Wizard с роутера',
			click: function() { confirmUninstall(); }
		}, [
			E('span', {}, '🗑'),
			'Удалить службу'
		]);

		var headerRightActions = E('div', {
			class: 'bcw-header-actions',
			style: 'display: flex; align-items: center; gap: 8px; flex-wrap: wrap;'
		}, [
			zapretBadgeEl,
			themeSelectEl,
			btnCheckUpdate,
			btnFeedback,
			btnUninstall
		]);

		var headerCard = E('div', { class: 'bcw-card', style: 'padding: 16px 20px;' }, [
			E('div', { style: 'display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 12px;' }, [
				E('div', {}, [
					E('h2', { class: 'bcw-header-title', style: 'margin: 0; font-size: 21px; display: flex; align-items: center; gap: 8px;' }, [
						'⚡ Zapret2Wizard — Мастер автономного обхода DPI (Zapret2)'
					]),
					E('div', { class: 'bcw-header-sub', style: 'font-size: 13px; opacity: 0.8; margin-top: 4px;' }, [
						'Быстрый подбор рабочих параметров DPI для роутера, сборка отказоустойчивых Circular-связок и внедрение в 1 клик.'
					])
				]),
				headerRightActions
			])
		]);
		mainLayout.appendChild(headerCard);

		// Update Notification Banner (Dynamic)
		var updateBannerCard = E('div', {
			class: 'bcw-card',
			style: 'padding: 14px 20px; background: rgba(0, 209, 178, 0.08); border: 1px solid #00d1b2; display: none;'
		});
		mainLayout.appendChild(updateBannerCard);

		// Target Selection Section (Tiles Grid)
		var quickChipsList = [
			{ id: 'preset_youtube', icon: '📺', name: 'YouTube' },
			{ id: 'preset_discord', icon: '💬', name: 'Discord' },
			{ id: 'preset_twitch', icon: '🎮', name: 'Twitch' },
			{ id: 'preset_x', icon: '🐦', name: 'X / Twitter' },
			{ id: 'preset_instagram', icon: '📸', name: 'Instagram' },
			{ id: 'builtin', icon: '🌐', name: 'Встроенные хосты (33)' },
			{ id: 'tcp16', icon: '⚡', name: 'TCP 16-20 KB' },
			{ id: 'domains', icon: '🎯', name: 'Свои домены' },
			{ id: 'test_strategy', icon: '🧪', name: 'Тест стратегии' }
		];

		var chipButtonsMap = {};
		var tilesGridEl = E('div', { class: 'bcw-tiles-grid' });

		quickChipsList.forEach(function(ch) {
			var btn = E('div', {
				class: 'bcw-tile-btn' + (currentTarget === ch.id ? ' active' : ''),
				click: function() { selectTarget(ch.id); }
			}, [
				E('div', { class: 'bcw-tile-icon' }, ch.icon),
				E('div', { class: 'bcw-tile-name' }, ch.name)
			]);
			chipButtonsMap[ch.id] = btn;
			tilesGridEl.appendChild(btn);
		});

		var customDomainInput = E('input', {
			type: 'text',
			class: 'cbi-input-text',
			placeholder: 'rutracker.org',
			value: 'rutracker.org',
			style: 'width: 100%; max-width: 380px; height: 38px; font-size: 14px; padding: 0 12px; box-sizing: border-box;'
		});

		var customDomainRow = E('div', {
			style: 'display: none; margin-top: 14px; padding: 12px 14px; background: var(--bcw-bg-card-sub); border-radius: 6px; border: 1px solid var(--bcw-border-sub);'
		}, [
			E('label', { style: 'font-weight: bold; margin-right: 10px; display: inline-block; margin-bottom: 4px;' }, 'Домены для поиска (через пробел):'),
			customDomainInput
		]);

		var testUrlInput = E('input', {
			type: 'text',
			class: 'cbi-input-text',
			style: 'width: 100%; max-width: 420px; height: 38px; font-size: 13px; font-family: monospace; padding: 0 12px; box-sizing: border-box;',
			value: 'https://googlevideo.com',
			placeholder: 'https://googlevideo.com или любой URL'
		});

		function guessUrlForStrategy(name) {
			var n = (name || '').toLowerCase();
			if (n.indexOf('tube') !== -1) return 'https://googlevideo.com';
			if (n.indexOf('discord') !== -1) return 'https://discord.com';
			if (n.indexOf('twitch') !== -1) return 'https://twitch.tv';
			if (n.indexOf('_x') !== -1 || n.indexOf('twitter') !== -1) return 'https://x.com';
			if (n.indexOf('instagram') !== -1) return 'https://gateway.instagram.com';
			return 'https://rutracker.org';
		}

		// Test Strategy Mode Dropdown
		var testStrategySelectEl = E('select', {
			class: 'bcw-select',
			style: 'width: 100%; max-width: 380px;',
			change: function(e) {
				var chosen = e.target.value;
				if (!chosen) return;
				var found = zapretAllStrategies.find(function(s) { return s.section === chosen; });
				if (found) {
					testUrlInput.value = guessUrlForStrategy(found.section);
					activeCodeEl.textContent = found.script || '# Скрипт стратегии пуст';
					activeMetaBadgesEl.innerHTML = '';
					activeMetaBadgesEl.appendChild(E('span', { class: 'badge', style: 'background: var(--bcw-btn-bg); color: var(--bcw-btn-color); border: 1px solid var(--bcw-btn-border); font-size: 11px;' }, 'Раздел: zapret2.' + found.section));
					activeMetaBadgesEl.appendChild(E('span', { class: 'badge', style: 'background: var(--bcw-btn-bg); color: var(--bcw-btn-color); border: 1px solid var(--bcw-btn-border); font-size: 11px;' }, 'Порт: ' + found.port));
					activeMetaBadgesEl.appendChild(found.enabled ?
						E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, '✓ Включена в Zapret2') :
						E('span', { class: 'badge cbi-color-red', style: 'font-size: 11px;' }, '✗ Отключена в Zapret2')
					);
					activeMetaBadgesEl.appendChild(found.is_circular ?
						E('span', { class: 'badge cbi-color-blue', style: 'font-size: 11px;' }, '🔄 Circular-связка') :
						E('span', { class: 'badge', style: 'background: var(--bcw-btn-bg); color: var(--bcw-btn-color); border: 1px solid var(--bcw-btn-border); font-size: 11px;' }, '⚡ Одиночная')
					);
					updateSummaryBox();
				}
			}
		}, [
			E('option', { value: '' }, '-- Выберите стратегию для теста --')
		]);

		zapretAllStrategies.forEach(function(st) {
			testStrategySelectEl.appendChild(E('option', { value: st.section }, st.section + (st.enabled ? ' [Включена]' : ' [Отключена]')));
		});

		var testStrategyHintBox = E('div', {
			class: 'bcw-test-hint-box'
		}, [
			E('strong', { style: 'color: #3273dc;' }, 'ℹ️ Режим «Тест стратегии»: '),
			E('span', {}, 'В этом режиме вы проверяете доступность сайтов через уже имеющуюся запись Zapret2. Нажмите кнопку '),
			E('strong', { style: 'color: #00d1b2;' }, '[ 🌐 Проверить доступность ]'),
			E('span', {}, ' в блоке управления ниже, чтобы отправить проверочный сетевой запрос на выбранный адрес. Кнопка [ ⚡ Запустить поиск ] нужна только если вы хотите с нуля подобрать новую связку.')
		]);

		var testStrategyRow = E('div', {
			style: 'display: none; margin-top: 14px; padding: 14px 16px; background: var(--bcw-bg-card-sub); border-radius: 6px; border: 1px solid var(--bcw-border-sub);'
		}, [
			E('div', { class: 'bcw-form-row' }, [
				E('label', { class: 'bcw-form-label' }, 'Стратегия Zapret2:'),
				testStrategySelectEl
			]),
			E('div', { class: 'bcw-form-row' }, [
				E('label', { class: 'bcw-form-label' }, 'Тестовый адрес / URL:'),
				testUrlInput
			]),
			testStrategyHintBox
		]);

		// Summary Banner
		var summaryTitleEl = E('strong', { style: 'color: #61afef; font-size: 14px;' }, 'YouTube (3 хоста)');
		var summaryDescEl = E('div', { style: 'font-size: 12px; opacity: 0.8; margin-top: 2px;' }, 'googlevideo.com, i.ytimg.com, youtube.com');
		var summaryStatusBadgeEl = E('span', { class: 'badge cbi-color-green', style: 'font-size: 12px; padding: 4px 10px;' }, '✓ Настроено в Zapret2');

		var targetSummaryBox = E('div', { class: 'bcw-target-summary' }, [
			E('div', {}, [
				summaryTitleEl,
				summaryDescEl
			]),
			summaryStatusBadgeEl
		]);

		// Mode Hint Box
		var modeHintTitleEl = E('span', { class: 'bcw-hint-header' }, '💡 Справка по режиму');
		var modeHintSummaryEl = E('div', { class: 'bcw-hint-summary' }, '');
		var modeHintGridEl = E('div', { class: 'bcw-hint-grid' }, []);

		var modeHintBox = E('div', { class: 'bcw-hint-box' }, [
			E('div', { style: 'display: flex; justify-content: space-between; align-items: center;' }, [
				modeHintTitleEl
			]),
			modeHintSummaryEl,
			modeHintGridEl
		]);

		var targetSectionCard = E('div', { class: 'bcw-card' }, [
			E('div', { class: 'bcw-card-header' }, [
				E('h3', { class: 'bcw-card-title' }, '1. Цель обхода (Пресеты Zapret Finder)')
			]),
			tilesGridEl,
			customDomainRow,
			testStrategyRow,
			targetSummaryBox
		]);
		mainLayout.appendChild(targetSectionCard);

		// Circular Checkbox Setting
		var paramCircularHintEl = E('div', {
			class: 'bcw-param-hint',
			style: 'margin-top: 4px; font-size: 12px; color: #abb2bf;'
		}, doCircular
			? '🔄 Circular: объединяет 2-3 независимые техники (Fake, Multisplit, Multidisorder) в ротацию. При сбое роутер на лету переключится на резервную.'
			: '⚡ Одиночная: применяется только одна лучшая техника обхода без резервной ротации.'
		);

		var chkCircular = E('input', {
			type: 'checkbox',
			id: 'bcw_chk_circular',
			class: 'bcw-chk-input',
			checked: doCircular,
			change: function(e) {
				doCircular = e.target.checked;
				if (paramCircularHintEl) {
					paramCircularHintEl.textContent = doCircular
						? '🔄 Circular: объединяет 2-3 независимые техники (Fake, Multisplit, Multidisorder) в ротацию. При сбое роутер на лету переключится на резервную.'
						: '⚡ Одиночная: применяется только одна лучшая техника обхода без резервной ротации.';
				}
			}
		});

		var circularToggleBox = E('div', {
			style: 'display: flex; flex-direction: column; gap: 4px; padding: 12px 16px; background: var(--bcw-bg-card-inner); border: 1px solid var(--bcw-border-sub); border-radius: 8px;'
		}, [
			E('label', {
				for: 'bcw_chk_circular',
				class: 'bcw-chk-wrap',
				style: 'margin: 0;'
			}, [
				chkCircular,
				E('span', { class: 'bcw-chk-box' }),
				E('span', { style: 'font-weight: 600; font-size: 13.5px; color: var(--bcw-text-title);' }, 'Собрать отказоустойчивую Circular-связку (авто-ротация при сбое DPI)')
			]),
			paramCircularHintEl
		]);

		var btnStartScan = E('button', {
			class: 'bcw-action-btn bcw-action-btn-primary',
			click: function() { startScan(); }
		}, [
			E('span', {}, '⚡'),
			E('span', {}, 'Запустить поиск')
		]);

		var btnStopScan = E('button', {
			class: 'bcw-action-btn bcw-action-btn-stop',
			style: 'display: none;',
			click: function() { stopScan(); }
		}, [
			E('span', {}, '⏹'),
			E('span', {}, 'Остановить')
		]);

		var btnTestConn = E('button', {
			class: 'bcw-action-btn bcw-action-btn-secondary',
			click: function() { testActiveConnection(); }
		}, [
			E('span', {}, '🌐'),
			E('span', {}, 'Проверить доступность')
		]);

		var btnSpeedTest = E('button', {
			class: 'bcw-action-btn bcw-action-btn-speed',
			title: 'Замер реальной скорости потокового видео и выявление DPI-троттлинга',
			click: function() { runSpeedTest(); }
		}, [
			E('span', {}, '⚡'),
			E('span', {}, 'Замер скорости')
		]);

		var actionsGridEl = E('div', { class: 'bcw-actions-grid' }, [
			btnStartScan,
			btnStopScan,
			btnTestConn,
			btnSpeedTest
		]);

		// Active Strategy Inspector Card
		var activeTargetTitleEl = E('span', { style: 'color: #3273dc; font-weight: bold;' }, 'YouTube');
		var activeMetaBadgesEl = E('div', { style: 'display: flex; flex-wrap: wrap; gap: 8px; align-items: center;' }, '');
		var activeCodeEl = E('pre', { class: 'bcw-code-box', style: 'max-height: 220px;' }, '');

		var btnCopyActive = E('button', {
			type: 'button',
			class: 'bcw-btn-sm cbi-button cbi-button-neutral',
			style: 'height: 30px; font-size: 12px; display: inline-flex; align-items: center; justify-content: center; gap: 6px;',
			click: function(e) {
				if (e && e.stopPropagation) e.stopPropagation();
				copyActiveStrategy();
			}
		}, '📋 Скопировать');

		var versionsSelectEl = E('select', {
			class: 'bcw-select',
			style: 'width: 100%; max-width: 320px; height: 32px; font-size: 12px; padding: 0 10px;',
			change: function(e) {
				var sec = e.target.value;
				if (!sec) return;
				selectSavedVersion(sec);
			}
		});

		var btnActivateVersion = E('button', {
			class: 'bcw-btn-sm cbi-button cbi-button-action',
			style: 'height: 32px; font-size: 12px; display: none; font-weight: bold; align-items: center; justify-content: center; gap: 6px;',
			click: function() {
				activateSelectedVersion();
			}
		}, '⚡ Активировать');

		var btnDeleteVersion = E('button', {
			class: 'bcw-btn-sm cbi-button cbi-button-negative',
			style: 'height: 32px; font-size: 12px; display: none; align-items: center; justify-content: center; gap: 6px;',
			click: function() {
				deleteSelectedVersion();
			}
		}, '🗑 Удалить');

		var versionsBarEl = E('div', {
			class: 'bcw-versions-bar',
			style: 'display: none; align-items: center; flex-wrap: wrap; gap: 10px; margin-top: 10px; padding: 8px 12px; background: var(--bcw-bg-card-sub); border-radius: 6px; border: 1px solid var(--bcw-border-sub);'
		}, [
			E('span', { style: 'font-size: 12px; color: var(--bcw-text-main); font-weight: 600;' }, '📁 История записей Zapret2:'),
			versionsSelectEl,
			E('div', { class: 'bcw-versions-actions', style: 'display: inline-flex; gap: 8px;' }, [
				btnActivateVersion,
				btnDeleteVersion
			])
		]);

		var isActiveStratExpanded = false;
		var activeStratBodyEl = E('div', {
			style: 'display: none; flex-direction: column; gap: 10px; margin-top: 14px;'
		}, [
			activeMetaBadgesEl,
			versionsBarEl,
			activeCodeEl
		]);

		var btnToggleActiveStrat = E('button', {
			type: 'button',
			class: 'bcw-btn-sm cbi-button cbi-button-neutral bcw-spoiler-btn',
			style: 'height: 30px; padding: 0 12px; font-size: 12px; font-weight: 600; display: inline-flex; align-items: center; gap: 6px; cursor: pointer; border-radius: 6px;'
		}, [
			E('span', { class: 'bcw-active-spoiler-icon' }, '▼'),
			E('span', { class: 'bcw-active-spoiler-text' }, 'Развернуть')
		]);

		var activeStratHeader = E('div', {
			class: 'bcw-card-header bcw-spoiler-header',
			style: 'cursor: pointer; user-select: none; margin-bottom: 0px; padding-bottom: 0px; border-bottom: none; display: flex; align-items: center; justify-content: space-between; transition: all 0.2s;'
		}, [
			E('div', { style: 'display: flex; align-items: center; gap: 10px; flex-wrap: wrap;' }, [
				E('span', { class: 'bcw-active-spoiler-arrow', style: 'display: inline-block; transition: all 0.2s; font-size: 13px; color: #61afef;' }, '▶'),
				E('h3', { class: 'bcw-card-title', style: 'margin: 0; font-size: 14px;' }, '🛡️ Активная стратегия в Zapret2:'),
				activeTargetTitleEl
			]),
			E('div', { style: 'display: flex; align-items: center; gap: 8px;' }, [
				btnCopyActive,
				btnToggleActiveStrat
			])
		]);

		function updateActiveStratSpoilerUI() {
			var arrowEl = activeStratHeader.querySelector('.bcw-active-spoiler-arrow');
			var btnTextEl = btnToggleActiveStrat.querySelector('.bcw-active-spoiler-text');
			var btnIconEl = btnToggleActiveStrat.querySelector('.bcw-active-spoiler-icon');

			if (isActiveStratExpanded) {
				activeStratBodyEl.style.display = 'flex';
				activeStratHeader.style.marginBottom = '14px';
				activeStratHeader.style.paddingBottom = '10px';
				activeStratHeader.style.borderBottom = '1px solid rgba(255,255,255,0.07)';
				if (arrowEl) {
					arrowEl.textContent = '▼';
					arrowEl.style.color = '#98c379';
				}
				if (btnTextEl) btnTextEl.textContent = 'Свернуть';
				if (btnIconEl) btnIconEl.textContent = '▲';
			} else {
				activeStratBodyEl.style.display = 'none';
				activeStratHeader.style.marginBottom = '0px';
				activeStratHeader.style.paddingBottom = '0px';
				activeStratHeader.style.borderBottom = 'none';
				if (arrowEl) {
					arrowEl.textContent = '▶';
					arrowEl.style.color = '#61afef';
				}
				if (btnTextEl) btnTextEl.textContent = 'Развернуть';
				if (btnIconEl) btnIconEl.textContent = '▼';
			}
		}

		function toggleActiveStratSpoiler() {
			isActiveStratExpanded = !isActiveStratExpanded;
			updateActiveStratSpoilerUI();
		}

		function expandActiveStratSpoiler() {
			isActiveStratExpanded = true;
			updateActiveStratSpoilerUI();
		}

		activeStratHeader.addEventListener('click', function(e) {
			toggleActiveStratSpoiler();
		});

		btnToggleActiveStrat.addEventListener('click', function(e) {
			e.stopPropagation();
			toggleActiveStratSpoiler();
		});

		var activeStratCard = E('div', { id: 'bcw-active-strat-card', class: 'bcw-card bcw-card-active-strat', style: 'border-left: 4px solid #3273dc;' }, [
			activeStratHeader,
			activeStratBodyEl
		]);
		// Note: activeStratCard is appended below scanner results as requested by user

		// Progress Monitor Card (Hidden when idle)
		var progressBarEl = E('div', {
			style: 'background: linear-gradient(90deg, #3273dc, #00d1b2); height: 100%; width: 0%; transition: width 0.3s ease;'
		});
		var progressTextEl = E('span', {}, 'Инициализация...');
		var progressPercentEl = E('span', { style: 'font-weight: bold;' }, '0%');
		var progressPhaseEl = E('h3', { class: 'bcw-card-title', style: 'color: #00d1b2;' }, 'Прогресс сканирования');

		var ispValEl = E('span', { style: 'color: #61afef; font-weight: 600;' }, (statusData.isp || 'Определение...'));
		var blockTypeValEl = E('span', { style: 'color: #e5c07b; font-weight: 600;' }, formatBlockType(statusData.block_type));

		var dpiFingerprintBadgesEl = E('span', {
			style: 'display: inline-flex; flex-wrap: wrap; gap: 6px; align-items: center;'
		}, [
			E('span', { style: 'color: var(--bcw-text-muted); font-style: italic;' }, 'Определяется во время подбора...')
		]);

		var dpiFingerprintRowEl = E('div', {
			class: 'bcw-dpi-fingerprint-row',
			style: 'margin-top: 10px; padding-top: 8px; border-top: 1px dashed var(--bcw-border-sub); display: flex; align-items: flex-start; gap: 8px; flex-wrap: wrap;'
		}, [
			E('div', { style: 'font-weight: 600; color: #61afef; display: flex; align-items: center; gap: 5px; min-width: 175px;' }, [
				E('span', {}, '🧬'),
				'DPI-профиль (уязвимости):'
			]),
			dpiFingerprintBadgesEl
		]);

		var lineParamsBoxEl = E('div', {
			class: 'bcw-line-params-box',
			style: 'margin-top: 14px; padding: 12px 16px; background: var(--bcw-bg-card-sub); border-radius: 6px; border: 1px solid var(--bcw-border-sub); font-size: 13px;'
		}, [
			E('div', { style: 'font-weight: bold; color: #00d1b2; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;' }, [
				E('span', {}, '📡'),
				'Исходные параметры линии и блокировки:'
			]),
			E('div', { class: 'bcw-line-grid' }, [
				E('div', {}, [
					E('strong', { style: 'color: var(--bcw-text-muted);' }, 'Провайдер: '),
					ispValEl
				]),
				E('div', {}, [
					E('strong', { style: 'color: var(--bcw-text-muted);' }, 'Тип блокировки: '),
					blockTypeValEl
				])
			]),
			dpiFingerprintRowEl
		]);

		var progressTimerEl = E('span', { style: 'font-size: 13px; color: #61afef; margin-left: 10px; font-weight: normal;' }, '');
		var btnCopyDiagOnError = E('button', {
			class: 'cbi-button cbi-button-action bcw-btn-diag-copy',
			style: 'display: none; margin-top: 14px; height: 38px; padding: 0 16px; font-size: 13px; font-weight: bold; background: #3273dc; color: #fff; border-color: #3273dc; align-items: center; justify-content: center; gap: 6px; cursor: pointer; border-radius: 6px;',
			click: function() { copyDiagnosticReport(); }
		}, '📋 Скопировать диагностический отчёт (GitHub / Telegram)');

		
		var monitorSuccessAlertEl = E('div', {
			class: 'bcw-applied-banner',
			style: 'display: none; margin: 12px 0 6px 0; background: rgba(0, 209, 178, 0.1); border: 1.5px solid #00d1b2; border-radius: 8px; padding: 14px 16px;'
		}, [
			E('div', { style: 'display: flex; align-items: flex-start; gap: 12px;' }, [
				E('span', { style: 'font-size: 24px; line-height: 1;' }, '🚀'),
				E('div', { style: 'flex: 1;' }, [
					E('div', { style: 'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px;' }, [
						E('strong', { style: 'color: #00d1b2; font-size: 14px;' }, 'Стратегия уже загружена в Zapret2 и активна!'),
						E('span', { class: 'badge cbi-color-green', style: 'font-weight: bold;' }, '✓ Zapret2 перезапущен')
					]),
					E('p', { style: 'margin: 6px 0 0 0; font-size: 13px; color: #e5e9f0; line-height: 1.5;' },
						'Служба уже перезапущена и прямо сейчас применяет обход для всех устройств в сети. ' +
						'Для моментальной проверки нажмите кнопку «Проверить доступность» выше.'
					)
				])
			])
		]);

		var monitorCard = E('div', {
			class: 'bcw-monitor-section',
			style: 'display: none; margin-top: 16px; padding-top: 16px; border-top: 1px solid rgba(255,255,255,0.08);'
		}, [
			E('div', { class: 'bcw-card-header', style: 'display: flex; align-items: center; justify-content: space-between; border-bottom: none; margin-bottom: 8px; padding-bottom: 0;' }, [
				E('div', { style: 'display: flex; align-items: center; flex-wrap: wrap; gap: 6px;' }, [
					progressPhaseEl,
					progressTimerEl
				])
			]),
			E('div', { style: 'background: #181a1f; border-radius: 8px; height: 20px; width: 100%; overflow: hidden; margin: 10px 0; border: 1px solid #383e4a;' }, [
				progressBarEl
			]),
			E('div', { style: 'display: flex; justify-content: space-between; font-size: 13px; opacity: 0.9;' }, [
				progressTextEl,
				progressPercentEl
			]),
			monitorSuccessAlertEl,
			lineParamsBoxEl,
			btnCopyDiagOnError
		]);

		var unifiedScanCard = E('div', { class: 'bcw-card' }, [
			E('div', { class: 'bcw-card-header' }, [
				E('h3', { class: 'bcw-card-title' }, '2. Подбор стратегий и сканирование')
			]),
			circularToggleBox,
			actionsGridEl,
			E('div', { style: 'font-size: 12px; color: #abb2bf; margin-top: 10px; display: flex; align-items: center; gap: 6px; padding: 4px 2px;' }, [
				E('span', { style: 'color: #00d1b2; font-weight: bold;' }, '⚡'),
				E('span', {}, 'Умный точный поиск: мгновенный экспресс-зонд DPI провайдера с авто-калибровкой лучших связок 2026 года под вашу сеть.')
			]),
			monitorCard
		]);
		mainLayout.appendChild(unifiedScanCard);

		var circularCard = { style: {} };

		// Individual Working Strategies Section (Collapsible Spoiler)
		var isStrategiesExpanded = false;
		var uniqueStrategiesCount = 0;
		var strategiesListEl = E('div', { style: 'display: none; flex-direction: column; gap: 12px; margin-top: 14px;' });

		var btnToggleStrategies = E('button', {
			type: 'button',
			class: 'bcw-btn-sm cbi-button cbi-button-neutral bcw-spoiler-btn',
			style: 'height: 30px; padding: 0 12px; font-size: 12px; font-weight: 600; display: inline-flex; align-items: center; gap: 6px; cursor: pointer; border-radius: 6px;'
		}, [
			E('span', { class: 'bcw-spoiler-icon' }, '▼'),
			E('span', { class: 'bcw-spoiler-text' }, 'Развернуть')
		]);

		var resultsCardHeader = E('div', {
			class: 'bcw-card-header bcw-spoiler-header',
			style: 'cursor: pointer; user-select: none; margin-bottom: 0px; padding-bottom: 0px; border-bottom: none; display: flex; align-items: center; justify-content: space-between; transition: all 0.2s;'
		}, [
			E('div', { style: 'display: flex; align-items: center; gap: 10px; flex-wrap: wrap;' }, [
				E('span', { class: 'bcw-spoiler-arrow', style: 'display: inline-block; transition: all 0.2s; font-size: 13px; color: #61afef;' }, '▶'),
				E('h3', { class: 'bcw-card-title', style: 'margin: 0;' }, 'Найденные рабочие стратегии (100% проверено)'),
				E('span', { class: 'badge cbi-color-blue bcw-strats-count-badge', style: 'font-size: 11px; padding: 2px 8px; border-radius: 10px; font-weight: bold;' }, '0 шт.')
			]),
			E('div', { style: 'display: flex; align-items: center; gap: 8px;' }, [
				btnToggleStrategies
			])
		]);

		function updateSpoilerUI() {
			var arrowEl = resultsCardHeader.querySelector('.bcw-spoiler-arrow');
			var btnTextEl = btnToggleStrategies.querySelector('.bcw-spoiler-text');
			var btnIconEl = btnToggleStrategies.querySelector('.bcw-spoiler-icon');
			var count = uniqueStrategiesCount || 0;

			if (isStrategiesExpanded) {
				strategiesListEl.style.display = 'flex';
				resultsCardHeader.style.marginBottom = '14px';
				resultsCardHeader.style.paddingBottom = '10px';
				resultsCardHeader.style.borderBottom = '1px solid rgba(255,255,255,0.07)';
				if (arrowEl) {
					arrowEl.textContent = '▼';
					arrowEl.style.color = '#98c379';
				}
				if (btnTextEl) btnTextEl.textContent = 'Свернуть';
				if (btnIconEl) btnIconEl.textContent = '▲';
			} else {
				strategiesListEl.style.display = 'none';
				resultsCardHeader.style.marginBottom = '0px';
				resultsCardHeader.style.paddingBottom = '0px';
				resultsCardHeader.style.borderBottom = 'none';
				if (arrowEl) {
					arrowEl.textContent = '▶';
					arrowEl.style.color = '#61afef';
				}
				if (btnTextEl) btnTextEl.textContent = count > 0 ? ('Развернуть (' + count + ')') : 'Развернуть';
				if (btnIconEl) btnIconEl.textContent = '▼';
			}
		}

		function toggleStrategiesSpoiler() {
			isStrategiesExpanded = !isStrategiesExpanded;
			updateSpoilerUI();
		}

		function expandStrategiesSpoiler() {
			isStrategiesExpanded = true;
			updateSpoilerUI();
		}

		resultsCardHeader.addEventListener('click', function(e) {
			toggleStrategiesSpoiler();
		});

		btnToggleStrategies.addEventListener('click', function(e) {
			e.stopPropagation();
			toggleStrategiesSpoiler();
		});

		var resultsCard = E('div', { class: 'bcw-card', style: 'display: none;' }, [
			resultsCardHeader,
			strategiesListEl
		]);

		// Active Strategy in Zapret2 (Placed right below scanner controls/progress)
		mainLayout.appendChild(activeStratCard);
		mainLayout.appendChild(resultsCard);

		// Live Logs and Diagnostics Monitor Card
		var consoleLogEl = E('pre', {
			class: 'bcw-code-box',
			style: 'height: 230px; font-size: 12px; line-height: 1.45;'
		}, logsData.scanner_log || 'Ожидание запуска сканера...');

		var chkAutoScroll = E('input', {
			type: 'checkbox',
			checked: autoLogScroll,
			style: 'cursor: pointer;',
			change: function(e) { autoLogScroll = e.target.checked; }
		});

		var logTabButtons = {};
		var logTabs = [
			{ id: 'scanner', title: '⚡ Лог BlockcheckW' },
			{ id: 'zapret2', title: '🛡️ Системный лог Zapret2' },
			{ id: 'daemons', title: '⚙️ Демоны nfqws2' }
		];

		var logTabsBar = E('div', { class: 'bcw-log-tabs' });
		logTabs.forEach(function(tb) {
			var btn = E('button', {
				class: 'bcw-log-tab-btn' + (activeLogTab === tb.id ? ' active' : ''),
				click: function() { switchLogTab(tb.id); }
			}, tb.title);
			logTabButtons[tb.id] = btn;
			logTabsBar.appendChild(btn);
		});

		var logCard = E('div', { class: 'bcw-card' }, [
			E('div', { class: 'bcw-card-header' }, [
				E('h3', { class: 'bcw-card-title' }, '📋 Мониторинг и логи службы'),
				E('div', { class: 'bcw-log-controls', style: 'display: flex; flex-wrap: wrap; gap: 8px; align-items: center;' }, [
					E('label', { style: 'font-size: 12px; display: flex; align-items: center; gap: 4px; cursor: pointer;' }, [
						chkAutoScroll,
						E('span', {}, 'Автоскролл')
					]),
					E('button', {
						class: 'bcw-btn-sm cbi-button cbi-button-neutral',
						style: 'height: 32px; padding: 0 12px; font-size: 12px; display: inline-flex; align-items: center; justify-content: center; gap: 4px;',
						click: function() { refreshLogs(); }
					}, '🔄 Обновить'),
					E('button', {
						class: 'bcw-btn-sm cbi-button cbi-button-reset',
						style: 'height: 32px; padding: 0 12px; font-size: 12px; display: inline-flex; align-items: center; justify-content: center; gap: 4px;',
						click: function() { consoleLogEl.textContent = ''; }
					}, '🗑 Очистить'),
					E('button', {
						class: 'bcw-btn-sm cbi-button cbi-button-action bcw-btn-diag-copy-header',
						style: 'height: 32px; padding: 0 12px; font-size: 12px; display: inline-flex; align-items: center; justify-content: center; gap: 4px; background: #3273dc; color: #fff; border-color: #3273dc; font-weight: 600;',
						click: function() { copyDiagnosticReport(); }
					}, '📋 Скопировать диагностический отчёт')
				])
			]),
			logTabsBar,
			E('div', { style: 'margin-top: 10px;' }, [ consoleLogEl ])
		]);
		mainLayout.appendChild(logCard);

		// Diagnostic and Duration Helpers
		var scanStartTime = null;
		var scanTimerInterval = null;
		var lastProgressChangeTime = Date.now();
		var lastPercentVal = -1;

		function formatDuration(ms) {
			if (!ms || ms < 0) return '00:00';
			var totalSec = Math.floor(ms / 1000);
			var min = Math.floor(totalSec / 60);
			var sec = totalSec % 60;
			return (min < 10 ? '0' + min : min) + ':' + (sec < 10 ? '0' + sec : sec);
		}

		function showDiagnosticModal(reportText) {
			var ta = E('textarea', {
				style: 'width: 100%; height: 320px; font-family: monospace; font-size: 11px; background: #14161a; color: #abb2bf; border: 1px solid #383e4a; border-radius: 4px; padding: 8px; box-sizing: border-box; resize: vertical;',
				readonly: 'readonly'
			}, reportText);

			bcwShowModal('📋 Диагностический отчёт для GitHub / Telegram', [
				E('p', { style: 'font-size: 13px; margin-bottom: 8px; color: #e5e9f0;' }, 'Выделите текст ниже и скопируйте его, чтобы прикрепить к обращению на GitHub или в Telegram:'),
				ta
			], [
				E('button', {
					class: 'cbi-button cbi-button-action',
					style: 'background: #00d1b2; color: #000; font-weight: bold;',
					click: function() {
						ta.focus();
						ta.select();
						try {
							document.execCommand('copy');
							ui.addNotification(null, E('p', {}, '✓ Скопировано в буфер обмена!'), 'info');
						} catch(e) {}
					}
				}, 'Выделить и скопировать'),
				E('button', {
					class: 'cbi-button cbi-button-neutral',
					click: function() { ui.hideModal(); }
				}, 'Закрыть')
			]);
			setTimeout(function() { ta.focus(); ta.select(); }, 100);
		}

		function copyDiagnosticReport() {
			var btns = document.querySelectorAll('.bcw-btn-diag-copy, .bcw-btn-diag-copy-header');
			btns.forEach(function(b) { b.textContent = '⏳ Сбор данных...'; });

			fs.exec(HELPER_BIN, ['diag', '--json']).then(function(res) {
				var reportText = '';
				if (res && res.stdout) {
					try {
						var d = JSON.parse(res.stdout);
						reportText = d.report || res.stdout;
					} catch(e) {
						reportText = res.stdout;
					}
				}
				if (!reportText || reportText.trim() === '') reportText = 'Ошибка получения диагностического отчета.';

				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(reportText).then(function() {
						ui.addNotification(null, E('p', {}, '✓ Диагностический отчёт скопирован в буфер обмена! Вы можете вставить его в обращение на GitHub или в Telegram.'), 'info');
						btns.forEach(function(b) { b.textContent = '✓ Скопировано!'; });
						setTimeout(function() {
							btns.forEach(function(b) { b.textContent = '📋 Скопировать диагностический отчёт'; });
						}, 3000);
					}).catch(function() {
						showDiagnosticModal(reportText);
						btns.forEach(function(b) { b.textContent = '📋 Скопировать диагностический отчёт'; });
					});
				} else {
					showDiagnosticModal(reportText);
					btns.forEach(function(b) { b.textContent = '📋 Скопировать диагностический отчёт'; });
				}
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, 'Ошибка сбора диагностического отчёта: ' + err), 'danger');
				btns.forEach(function(b) { b.textContent = '📋 Скопировать диагностический отчёт'; });
			});
		}

		// Business Logic Functions

		function updateActiveStrategyDisplay() {
			var pDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'];
			var targetKey = pDef.key || currentTarget;
			var sData = zapretServicesData[targetKey];

			activeTargetTitleEl.textContent = pDef.name;
			activeMetaBadgesEl.innerHTML = '';

			if (currentTarget === 'test_strategy') {
				var chosen = testStrategySelectEl.value;
				var found = zapretAllStrategies.find(function(s) { return s.section === chosen; });
				if (found) {
					activeTargetTitleEl.textContent = 'Тест стратегии (' + found.section + ')';
					activeCodeEl.textContent = found.script || '# Скрипт стратегии пуст';
					activeMetaBadgesEl.appendChild(E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' }, 'Раздел: zapret2.' + found.section));
					activeMetaBadgesEl.appendChild(E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' }, 'Порт: ' + found.port));
					activeMetaBadgesEl.appendChild(found.enabled ?
						E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, '✓ Включена в Zapret2') :
						E('span', { class: 'badge cbi-color-red', style: 'font-size: 11px;' }, '✗ Отключена в Zapret2')
					);
					activeMetaBadgesEl.appendChild(found.is_circular ?
						E('span', { class: 'badge cbi-color-blue', style: 'font-size: 11px;' }, '🔄 Circular-связка') :
						E('span', { class: 'badge', style: 'background: #485060; color: #fff; font-size: 11px;' }, '⚡ Одиночная')
					);
				} else {
					activeTargetTitleEl.textContent = 'Тест стратегии';
					activeCodeEl.textContent = '# Выберите стратегию для тестирования в выпадающем списке выше';
				}
				versionsBarEl.style.display = 'none';
				return;
			}

			if (sData && sData.script && sData.script.trim() !== '') {
				var isDiscordTarget = (currentTarget === 'preset_discord' || currentTarget === 'discord');
				var secBadge = E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' },
					(isDiscordTarget && sData.dual_circuit) ? ('Контур TCP: zapret2.' + sData.section) : ('Раздел: zapret2.' + sData.section)
				);
				var portBadge = E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' },
					(isDiscordTarget && sData.dual_circuit) ? ('Порт TCP: ' + sData.port) : ('Порт: ' + sData.port)
				);
				var statusBadge = sData.enabled ?
					E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, '✓ Включена') :
					E('span', { class: 'badge cbi-color-red', style: 'font-size: 11px;' }, '✗ Отключена');
				var circBadge = sData.is_circular ?
					E('span', { class: 'badge cbi-color-blue', style: 'font-size: 11px;' }, '🔄 Circular-связка') :
					E('span', { class: 'badge', style: 'background: #485060; color: #fff; font-size: 11px;' }, '⚡ Одиночная');

				activeMetaBadgesEl.appendChild(secBadge);
				activeMetaBadgesEl.appendChild(portBadge);
				activeMetaBadgesEl.appendChild(statusBadge);
				activeMetaBadgesEl.appendChild(circBadge);

				if (isDiscordTarget && sData.dual_circuit && sData.voice_circuit) {
					var vc = sData.voice_circuit;
					var voiceBadge = E('span', {
						class: 'badge',
						style: 'background: rgba(88, 101, 242, 0.25); color: #7289da; border: 1px solid rgba(88, 101, 242, 0.4); font-size: 11px;'
					}, '🎙️ VoiceFlow: ' + (vc.enabled ? '✓ Активен' : '✗ Отключен') + ' (' + vc.section + ', UDP ' + vc.port + ')');
					activeMetaBadgesEl.appendChild(voiceBadge);
				}

				if (sData.versions_count && sData.versions_count > 1) {
					var verCountBadge = E('span', { class: 'badge', style: 'background: #4b5263; color: #61afef; font-size: 11px;' }, '📁 Всего записей: ' + sData.versions_count);
					activeMetaBadgesEl.appendChild(verCountBadge);
				}

				if (isDiscordTarget && sData.dual_circuit && sData.voice_circuit && sData.voice_circuit.script) {
					activeCodeEl.textContent = '# [Контур 1: TCP 443 — Чат, WebSockets & API (' + sData.section + ')]\n' + sData.script +
						'\n\n# [Контур 2: VoiceFlow UDP 50000-65535, 19294-19344 — WebRTC Voice & STUN (' + sData.voice_circuit.section + ')]\n' + sData.voice_circuit.script;
				} else {
					activeCodeEl.textContent = sData.script;
				}

				// Update versions history dropdown
				if (versionsSelectEl && versionsBarEl && sData.versions && sData.versions.length > 1) {
					versionsBarEl.style.display = 'flex';
					versionsSelectEl.innerHTML = '';
					sData.versions.forEach(function(v) {
						var opt = E('option', { value: v.section }, v.section + (v.enabled ? ' (✓ Активна)' : ' (Отключена)'));
						if (v.section === sData.section) opt.selected = true;
						versionsSelectEl.appendChild(opt);
					});
					btnActivateVersion.style.display = 'none';
					btnDeleteVersion.style.display = 'none';
				} else if (versionsBarEl) {
					versionsBarEl.style.display = 'none';
				}
			} else {
				if (versionsBarEl) versionsBarEl.style.display = 'none';
				activeMetaBadgesEl.appendChild(
					E('span', { class: 'badge cbi-color-neutral', style: 'font-size: 11px;' }, 'Стратегия не настроена')
				);
				activeCodeEl.textContent = '# Стратегия для выбранной цели (' + pDef.name + ') ещё не настроена в Zapret2.\n# Запустите турбо-поиск выше для автоматического подбора и активации!';
			}
		}

		function selectSavedVersion(sec) {
			var pDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'];
			var targetKey = pDef.key || currentTarget;
			var sData = zapretServicesData[targetKey];
			if (!sData || !sData.versions) return;

			var v = sData.versions.find(function(item) { return item.section === sec; });
			if (!v) return;

			activeCodeEl.textContent = v.script;
			activeMetaBadgesEl.innerHTML = '';

			var secBadge = E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' }, 'Раздел: zapret2.' + v.section);
			var portBadge = E('span', { class: 'badge', style: 'background: #3e4451; color: #fff; font-size: 11px;' }, 'Порт: ' + v.port);
			var statusBadge = v.enabled ?
				E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, '✓ Включена') :
				E('span', { class: 'badge cbi-color-red', style: 'font-size: 11px;' }, '✗ Отключена');
			var circBadge = v.is_circular ?
				E('span', { class: 'badge cbi-color-blue', style: 'font-size: 11px;' }, '🔄 Circular-связка') :
				E('span', { class: 'badge', style: 'background: #485060; color: #fff; font-size: 11px;' }, '⚡ Одиночная');

			activeMetaBadgesEl.appendChild(secBadge);
			activeMetaBadgesEl.appendChild(portBadge);
			activeMetaBadgesEl.appendChild(statusBadge);
			activeMetaBadgesEl.appendChild(circBadge);

			if (sData.versions_count && sData.versions_count > 1) {
				var verCountBadge = E('span', { class: 'badge', style: 'background: #4b5263; color: #61afef; font-size: 11px;' }, '📁 Всего записей: ' + sData.versions_count);
				activeMetaBadgesEl.appendChild(verCountBadge);
			}

			if (!v.enabled) {
				btnActivateVersion.style.display = 'inline-flex';
				btnActivateVersion.textContent = '⚡ Активировать ' + v.section;
				btnDeleteVersion.style.display = 'inline-flex';
			} else {
				btnActivateVersion.style.display = 'none';
				btnDeleteVersion.style.display = 'none';
			}
		}

		function activateSelectedVersion() {
			var chosenSec = versionsSelectEl ? versionsSelectEl.value : null;
			if (!chosenSec) return;

			bcwShowModal('Активация стратегии', [
				E('p', { class: 'spinning' }, 'Переключение на запись ' + chosenSec + ' в Zapret2...')
			]);

			fs.exec(HELPER_BIN, ['activate', '--target', currentTarget, '--section', chosenSec]).then(function(res) {
				ui.hideModal();
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				if (parsed && parsed.success) {
					getZapretInfo().then(function(info) {
						zapretServicesData = info.services || {};
						zapretAllStrategies = info.all_strategies || [];
						updateSummaryBox();
						updateActiveStrategyDisplay();
						if (zapretBadgeEl) {
							zapretBadgeEl.className = 'bcw-header-item ' + ((info.zapret2_running === 'running') ? 'badge cbi-color-green' : 'badge cbi-color-red');
							zapretBadgeEl.textContent = (info.zapret2_running === 'running') ? '✓ Zapret2Wizard активен' : '✗ Zapret2Wizard остановлен';
						}
					});
					refreshLogs();
					lastAppliedResult = parsed;

					showStrategyAppliedModal({
						section: chosenSec,
						isAuto: false,
						connected: true
					});
				} else {
					ui.addNotification(null, E('p', {}, 'Ошибка активации: ' + (parsed ? parsed.error : res.stderr)), 'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Ошибка активации: ' + err), 'danger');
			});
		}

		function deleteSelectedVersion() {
			var chosenSec = versionsSelectEl ? versionsSelectEl.value : null;
			if (!chosenSec) return;

			if (!confirm('Вы уверены, что хотите удалить сохранённую запись ' + chosenSec + ' из конфигурации Zapret2?')) {
				return;
			}

			bcwShowModal('Удаление стратегии', [
				E('p', { class: 'spinning' }, 'Удаление записи ' + chosenSec + ' из Zapret2...')
			]);

			fs.exec(HELPER_BIN, ['delete_strategy', chosenSec]).then(function(res) {
				ui.hideModal();
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				if (parsed && parsed.success) {
					ui.addNotification(null, E('p', {}, '✓ Запись ' + chosenSec + ' удалена.'), 'info');
					getZapretInfo().then(function(info) {
						zapretServicesData = info.services || {};
						zapretAllStrategies = info.all_strategies || [];
						updateSummaryBox();
						updateActiveStrategyDisplay();
					});
					refreshLogs();
				} else {
					ui.addNotification(null, E('p', {}, 'Ошибка удаления: ' + (parsed ? parsed.error : res.stderr)), 'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Ошибка: ' + err), 'danger');
			});
		}

		function updateModeHint() {
			// Mode hint box removed for a cleaner, compact interface
		}

		function updateSummaryBox() {
			var pDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'];
			summaryTitleEl.textContent = pDef.icon + ' ' + pDef.name;
			summaryDescEl.textContent = pDef.domainsText || pDef.domain;

			if (currentTarget === 'test_strategy') {
				var chosen = testStrategySelectEl.value;
				var found = zapretAllStrategies.find(function(s) { return s.section === chosen; });
				if (found) {
					summaryTitleEl.textContent = '🧪 Тест стратегии: zapret2.' + found.section;
					summaryDescEl.textContent = 'Порт: ' + found.port + ' • ' + (found.is_circular ? 'Circular-связка' : 'Одиночная стратегия');
					summaryStatusBadgeEl.className = found.enabled ? 'badge cbi-color-green' : 'badge cbi-color-red';
					summaryStatusBadgeEl.textContent = found.enabled ? '✓ Запись включена в Zapret2' : '✗ Запись отключена в Zapret2';
				} else {
					summaryStatusBadgeEl.className = 'badge cbi-color-neutral';
					summaryStatusBadgeEl.textContent = 'Выберите стратегию выше';
				}
			} else {
				var sData = zapretServicesData[pDef.key || currentTarget];
				if (sData && sData.enabled) {
					if ((currentTarget === 'preset_discord' || currentTarget === 'discord') && sData.dual_circuit && sData.voice_circuit && sData.voice_circuit.enabled) {
						summaryStatusBadgeEl.className = 'badge cbi-color-blue';
						summaryStatusBadgeEl.textContent = '🎙️ Dual-Circuit: TCP (' + sData.section + ') + Voice RTC (UDP)';
					} else {
						summaryStatusBadgeEl.className = sData.is_circular ? 'badge cbi-color-blue' : 'badge cbi-color-green';
						summaryStatusBadgeEl.textContent = sData.is_circular ? '🔄 Активна Circular-связка (' + sData.section + ')' : '✓ Активна стратегия (' + sData.section + ')';
					}
				} else {
					summaryStatusBadgeEl.className = 'badge cbi-color-neutral';
					summaryStatusBadgeEl.textContent = 'Не настроено в Zapret2';
				}
			}

			updateModeHint();
		}

		function selectTarget(targetId) {
			currentTarget = targetId;

			// Update chips
			quickChipsList.forEach(function(ch) {
				var b = chipButtonsMap[ch.id];
				if (b) {
					if (ch.id === targetId) b.classList.add('active');
					else b.classList.remove('active');
				}
			});

			customDomainRow.style.display = (targetId === 'domains' ? 'block' : 'none');
			testStrategyRow.style.display = (targetId === 'test_strategy' ? 'block' : 'none');

			if (targetId === 'test_strategy' && !testStrategySelectEl.value) {
				var defStrat = zapretAllStrategies.find(function(s) { return s.enabled; }) || zapretAllStrategies[0];
				if (defStrat) {
					testStrategySelectEl.value = defStrat.section;
					testUrlInput.value = guessUrlForStrategy(defStrat.section);
				}
			}

			updateSummaryBox();
			updateActiveStrategyDisplay();
		}

		function switchApplyMode(isAuto) {
			autoApply = isAuto;
		}

		function switchCircularMode(isCirc) {
			doCircular = isCirc;
			if (chkCircular) chkCircular.checked = isCirc;
			if (paramCircularHintEl) {
				paramCircularHintEl.textContent = isCirc
					? '🔄 Circular: объединяет 2-3 независимые техники (Fake, Multisplit, Multidisorder) в ротацию. При сбое роутер на лету переключится на резервную.'
					: '⚡ Одиночная: применяется только одна лучшая техника обхода без резервной ротации.';
			}
		}

		function switchLogTab(tabId) {
			activeLogTab = tabId;
			logTabs.forEach(function(tb) {
				var b = logTabButtons[tb.id];
				if (b) {
					if (tb.id === tabId) b.classList.add('active');
					else b.classList.remove('active');
				}
			});
			refreshLogs();
		}

		function refreshLogs() {
			return getLogs().then(function(lg) {
				var text = '';
				if (activeLogTab === 'scanner') {
					text = lg.scanner_log || 'Лог сканера пуст. Запустите поиск.';
				} else if (activeLogTab === 'zapret2') {
					text = lg.zapret2_log || 'Лог Zapret2 пуст.';
				} else if (activeLogTab === 'daemons') {
					text = lg.daemons || 'Активные процессы nfqws2 не обнаружены.';
				}
				consoleLogEl.textContent = text;
				if (autoLogScroll) {
					consoleLogEl.scrollTop = consoleLogEl.scrollHeight;
				}
			});
		}

		function copyActiveStrategy() {
			if (activeCodeEl && activeCodeEl.textContent) {
				navigator.clipboard.writeText(activeCodeEl.textContent).then(function() {
					ui.addNotification(null, E('p', {}, '✓ Стратегия скопирована в буфер обмена!'), 'info');
				}).catch(function() {
					ui.addNotification(null, E('p', {}, 'Выделите текст и скопируйте вручную.'), 'warning');
				});
			}
		}

		
		function showStrategyAppliedModal(opts) {
			opts = opts || {};
			var isAuto = opts.isAuto !== false;
			var targetDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'] || {};
			var currentService = zapretServicesData[currentTarget] || {};
			var currentActive = currentService.active || {};

			var defSec = (currentTarget === 'preset_youtube') ? 'BlockcheckW_YouTube' :
			             (currentTarget === 'preset_discord') ? 'BlockcheckW_Discord' :
			             (currentTarget === 'preset_x') ? 'BlockcheckW_X' :
			             (currentTarget === 'preset_instagram') ? 'BlockcheckW_Instagram' :
			             (currentTarget === 'preset_twitch') ? 'BlockcheckW_Twitch' :
			             (currentTarget === 'builtin') ? 'BlockcheckW_General' :
			             ('BlockcheckW_' + currentTarget.replace(/[^a-zA-Z0-9_]/g, '_'));

			var candidateSec = (opts && opts.section) ||
			                   (opts && opts.applyResult && opts.applyResult.section) ||
			                   currentActive.section ||
			                   (currentService && currentService.section) ||
			                   defSec;
			var sectionName = (candidateSec && candidateSec !== 'undefined' && candidateSec !== 'null') ? candidateSec : defSec;

			var targetLabel = targetDef.name || targetDef.label || currentTarget;
			if (currentTarget === 'domains') {
				var d = customDomainInput ? customDomainInput.value.trim() : '';
				if (d) targetLabel = 'Домен ' + d;
			}

			var httpCode = (opts.applyResult && opts.applyResult.http_code) || opts.httpCode || null;
			var isConnected = (opts.applyResult && opts.applyResult.connected) || opts.connected || (httpCode && parseInt(httpCode) > 0);

			var body = [
				E('div', {
					style: 'background: rgba(0, 209, 178, 0.12); border: 1.5px solid #00d1b2; border-radius: 8px; padding: 14px 16px; margin-bottom: 14px;'
				}, [
					E('div', { style: 'display: flex; align-items: center; gap: 10px; font-weight: bold; font-size: 15px; color: #00d1b2;' }, [
						E('span', { style: 'font-size: 24px; line-height: 1;' }, '🚀'),
						E('span', {}, 'Вам ничего не нужно настраивать — всё уже работает!')
					]),
					E('p', { style: 'margin: 8px 0 0 0; font-size: 13px; color: #e5e9f0; line-height: 1.5;' },
						'Найденная стратегия уже ' + (isAuto ? 'автоматически' : 'успешно') + ' сохранена в конфигурацию роутера, а служба Zapret2 перезапущена. ' +
						'Обход блокировок уже активен для всех подключенных устройств в домашней сети (телефоны, компьютеры, Smart TV).'
					)
				]),

				E('div', {
					style: 'background: #1c2027; border: 1px solid #282c34; border-radius: 6px; padding: 12px 14px; margin-bottom: 14px; font-size: 13px; display: flex; flex-direction: column; gap: 8px;'
				}, [
					E('div', { style: 'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 4px;' }, [
						E('span', { style: 'color: #abb2bf;' }, '🎯 Направление:'),
						E('strong', { style: 'color: #61afef;' }, targetLabel)
					]),
					E('div', { style: 'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 4px;' }, [
						E('span', { style: 'color: #abb2bf;' }, '📁 Запись в Zapret2:'),
						E('code', { style: 'background: #282c34; padding: 2px 6px; border-radius: 4px; color: #98c379; font-weight: bold; font-size: 12px;' }, 'zapret2.' + sectionName)
					]),
					E('div', { style: 'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 4px;' }, [
						E('span', { style: 'color: #abb2bf;' }, '⚙️ Статус службы:'),
						E('span', { style: 'color: #98c379; font-weight: bold;' }, '✓ Zapret2 перезапущен и активен')
					]),
					isConnected ? E('div', { style: 'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 4px;' }, [
						E('span', { style: 'color: #abb2bf;' }, '🌐 Проверка сети:'),
						E('span', { style: 'color: #98c379; font-weight: bold;' }, '✓ Ресурс успешно отвечает' + (httpCode ? ' (HTTP ' + httpCode + ')' : ''))
					]) : null
				].filter(Boolean)),

				E('div', { style: 'font-size: 13px; line-height: 1.5; color: #abb2bf;' }, [
					E('strong', { style: 'color: #e5e9f0; display: block; margin-bottom: 6px;' }, '💡 Как проверить работу прямо сейчас:'),
					E('div', { style: 'display: flex; flex-direction: column; gap: 4px; padding-left: 4px;' }, [
						E('div', {}, '1. Откройте нужный сервис (например, видео на YouTube) на телефоне или ПК.'),
						E('div', {}, '2. Если вкладка уже была открыта — обновите её (на ПК: Ctrl + F5).'),
						E('div', {}, '3. Или нажмите кнопку проверки ниже, чтобы роутер сам выполнил проверочный сетевой запрос.')
					])
				])
			];

			var actions = [
				E('button', {
					class: 'cbi-button cbi-button-action',
					style: 'background: #3273dc; color: #fff; font-weight: bold; padding: 6px 16px;',
					click: function() {
						ui.hideModal();
						testActiveConnection();
					}
				}, '🌐 Проверить доступность'),
				E('button', {
					class: 'cbi-button cbi-button-positive',
					style: 'background: #00d1b2; color: #000; font-weight: bold; padding: 6px 18px;',
					click: function() {
						ui.hideModal();
						var activeCard = document.getElementById('bcw-active-strat-card') || document.querySelector('.bcw-card-active-strat');
						if (activeCard) {
							if (typeof expandActiveStratSpoiler === 'function') {
								expandActiveStratSpoiler();
							}
							activeCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
							activeCard.classList.add('bcw-highlight-pulse');
							setTimeout(function() { activeCard.classList.remove('bcw-highlight-pulse'); }, 2500);
						}
					}
				}, '✓ Отлично, понятно!')
			];

			bcwShowModal('🎉 Стратегия успешно активирована в Zapret2!', body, actions);
		}

		function showManualStrategiesFoundModal(count) {
			var body = [
				E('div', {
					style: 'background: rgba(255, 183, 77, 0.12); border: 1.5px solid #ffb74d; border-radius: 8px; padding: 14px 16px; margin-bottom: 14px;'
				}, [
					E('div', { style: 'display: flex; align-items: center; gap: 10px; font-weight: bold; font-size: 15px; color: #ffb74d;' }, [
						E('span', { style: 'font-size: 24px; line-height: 1;' }, '⚠️'),
						E('span', {}, 'Внимание: стратегия ещё НЕ загружена в Zapret2!')
					]),
					E('p', { style: 'margin: 8px 0 0 0; font-size: 13px; color: #e5e9f0; line-height: 1.5;' },
						'Поиск успешно завершён, найдено рабочих стратегий: ' + count + '. ' +
						'Так как включен ручной режим применения, стратегия пока не активирована на роутере.'
					)
				]),

				E('div', { style: 'font-size: 13px; line-height: 1.5; color: #abb2bf;' }, [
					E('strong', { style: 'color: #e5e9f0; display: block; margin-bottom: 6px;' }, '👉 Чтобы активировать обход:'),
					E('p', {}, 'В таблице результатов ниже выберите нужную стратегию и нажмите зелёную кнопку:'),
					E('div', { style: 'margin: 10px 0; display: flex; justify-content: center;' }, [
						E('span', {
							class: 'cbi-button cbi-button-positive',
							style: 'pointer-events: none; padding: 4px 14px; font-weight: bold; font-size: 12px;'
						}, '✓ Применить в Zapret2')
					]),
					E('p', { style: 'font-size: 12px; color: #98c379;' }, 'После нажатия роутер сам запишет её в Zapret2 и перезапустит службу.')
				])
			];

			var actions = [
				E('button', {
					class: 'cbi-button cbi-button-action',
					style: 'background: #3273dc; color: #fff; font-weight: bold; padding: 6px 18px;',
					click: function() {
						ui.hideModal();
						if (resultsCard) {
							if (typeof expandStrategiesSpoiler === 'function') {
								expandStrategiesSpoiler();
							}
							resultsCard.scrollIntoView({ behavior: 'smooth', block: 'start' });
						}
					}
				}, '👇 Выбрать стратегию из списка')
			];

			bcwShowModal('🔍 Найдено рабочих стратегий: ' + count, body, actions);
		}

		function startScan() {
			var domain = '';
			if (currentTarget === 'domains') {
				domain = customDomainInput.value.trim();
				if (!domain) {
					ui.addNotification(null, E('p', {}, 'Пожалуйста, укажите домен для проверки!'), 'danger');
					return;
				}
				domain = domain.replace(/^https?:\/\//i, '').replace(/\/.*$/, '').trim();
			}

			btnStartScan.style.display = 'none';
			btnStopScan.style.display = 'inline-flex';
			monitorCard.style.display = 'block';
			circularCard.style.display = 'none';
			resultsCard.style.display = 'none';
			isStrategiesExpanded = false;
			updateSpoilerUI();
			btnCopyDiagOnError.style.display = 'none';
			monitorSuccessAlertEl.style.display = 'none';
			activeScanInProgress = true;
			ispValEl.textContent = 'Определение...';
			blockTypeValEl.textContent = 'Определение...';
			dpiFingerprintBadgesEl.innerHTML = '';
			dpiFingerprintBadgesEl.appendChild(E('span', { style: 'color: var(--bcw-text-muted); font-style: italic;' }, 'Определяется во время подбора...'));

			progressBarEl.style.background = 'linear-gradient(90deg, #3273dc, #00d1b2)';
			progressPhaseEl.textContent = 'Запуск подбора...';
			progressPhaseEl.style.color = '#00d1b2';
			progressBarEl.style.width = '10%';
			progressPercentEl.textContent = '10%';
			progressTextEl.textContent = 'Инициализация подбора стратегий...';

			var helperArgs = [
				'start',
				'--target', currentTarget,
				'--mode', currentMode,
				'--circular', doCircular ? '1' : '0',
				'--auto-apply', autoApply ? '1' : '0',
				'--workers', '2'
			];
			if (domain) {
				helperArgs.push('--domain', domain);
			}

			isRunning = true;
			scanStartTime = Date.now();
			lastProgressChangeTime = Date.now();
			lastPercentVal = 10;
			progressTimerEl.textContent = '⏱ 00:00';

			if (scanTimerInterval) clearInterval(scanTimerInterval);
			scanTimerInterval = setInterval(function() {
				if (isRunning && scanStartTime) {
					progressTimerEl.textContent = '⏱ ' + formatDuration(Date.now() - scanStartTime);
				}
			}, 1000);

			fs.exec(HELPER_BIN, helperArgs).then(function(res) {
				if (res && res.stdout) {
					try {
						var parsed = JSON.parse(res.stdout);
						if (parsed.error) {
							ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + parsed.error), 'danger');
							resetScanUI();
							return;
						}
					} catch(e) {}
				}
				startPolling();
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, 'Ошибка запуска сканера: ' + err), 'danger');
				resetScanUI();
			});
		}

		function stopScan() {
			activeScanInProgress = false;
			fs.exec(HELPER_BIN, ['stop']).then(function() {
				ui.addNotification(null, E('p', {}, 'Сканирование остановлено пользователем.'), 'info');
				resetScanUI();
				refreshLogs();
			});
		}

		function resetScanUI() {
			isRunning = false;
			if (pollInterval) {
				clearInterval(pollInterval);
				pollInterval = null;
			}
			if (scanTimerInterval) {
				clearInterval(scanTimerInterval);
				scanTimerInterval = null;
			}
			btnStartScan.style.display = 'inline-flex';
			btnStopScan.style.display = 'none';
		}

		function startPolling() {
			if (pollInterval) clearInterval(pollInterval);
			pollInterval = setInterval(function() {
				checkHelperStatus().then(function(st) {
					updateProgressUI(st);
					if (st.status === 'done' || st.status === 'idle') {
						var wasActive = activeScanInProgress;
						activeScanInProgress = false;
						resetScanUI();
						getZapretInfo().then(function(info) {
							zapretServicesData = info.services || {};
							zapretAllStrategies = info.all_strategies || [];
							updateSummaryBox();
							updateActiveStrategyDisplay();
							if (zapretBadgeEl) {
								zapretBadgeEl.className = 'bcw-header-item ' + ((info.zapret2_running === 'running') ? 'badge cbi-color-green' : 'badge cbi-color-red');
								zapretBadgeEl.textContent = (info.zapret2_running === 'running') ? '✓ Zapret2Wizard активен' : '✗ Zapret2Wizard остановлен';
							}
						});
						refreshLogs();

						var stratsCount = (st.strategies && Array.isArray(st.strategies)) ? st.strategies.length : 0;
						var hasStrategies = stratsCount > 0;

						var isAutoApplied = (st.auto_applied === true) || (st.apply_result && st.apply_result.success === true);
						if (st.apply_result) {
							lastAppliedResult = st.apply_result;
						}
						if (isAutoApplied) {
							monitorSuccessAlertEl.style.display = 'block';
						}

						if (wasActive) {
							if (isAutoApplied) {
								showStrategyAppliedModal({
									isAuto: true,
									section: (st.apply_result && st.apply_result.section) || null,
									applyResult: st.apply_result,
									connected: st.apply_result ? st.apply_result.connected : true,
									httpCode: st.apply_result ? st.apply_result.http_code : null
								});
							} else if (hasStrategies) {
								showManualStrategiesFoundModal(stratsCount);
							} else {
								bcwShowModal('Результат поиска', [
									E('p', { class: 'cbi-color-yellow', style: 'font-weight: bold; font-size: 14px;' }, '⚠️ Рабочих стратегий не найдено'),
									E('p', { style: 'font-size: 13px; color: #abb2bf; margin-top: 8px;' }, 'Попробуйте запустить «Глубокий скан» для полного перебора или проверьте доступность интернета/домена.')
								], [
									E('button', {
										class: 'cbi-button cbi-button-neutral',
										click: function() { ui.hideModal(); }
									}, 'Закрыть')
								]);
							}
						}
					} else if (st.status === 'error') {
						activeScanInProgress = false;
						resetScanUI();
						ui.addNotification(null, E('p', {}, st.phase || 'Ошибка сканирования. Проверьте домен и логи.'), 'danger');
						refreshLogs();
					}
				});
			}, 1500);
		}

		function updateProgressUI(st) {
			var pct = st.percent || 0;
			progressBarEl.style.width = pct + '%';
			progressPercentEl.textContent = pct + '%';
			progressTextEl.textContent = st.phase || '';

			if (pct !== lastPercentVal) {
				lastPercentVal = pct;
				lastProgressChangeTime = Date.now();
			}

			if (st.status === 'done') {
				progressPhaseEl.textContent = 'Сканирование завершено';
				progressPhaseEl.style.color = '#00d1b2';
				progressBarEl.style.background = '#00d1b2';
				btnCopyDiagOnError.style.display = 'none';
				if (st.auto_applied || (st.apply_result && st.apply_result.success)) {
					monitorSuccessAlertEl.style.display = 'block';
				}
			} else if (st.status === 'error') {
				progressPhaseEl.textContent = 'Ошибка сканирования';
				progressPhaseEl.style.color = '#ff3860';
				progressBarEl.style.background = '#ff3860';
				btnCopyDiagOnError.style.display = 'inline-flex';
			} else if (st.status === 'running') {
				progressBarEl.style.background = 'linear-gradient(90deg, #3273dc, #00d1b2)';
				// Stall protection: show diagnostic button if no progress for > 180s
				if (Date.now() - lastProgressChangeTime > 180000) {
					btnCopyDiagOnError.style.display = 'inline-flex';
				} else {
					btnCopyDiagOnError.style.display = 'none';
				}
			}

			if (st.isp && st.isp.trim() !== '') {
				ispValEl.textContent = st.isp;
			}
			if (st.block_type && st.block_type.trim() !== '') {
				blockTypeValEl.textContent = formatBlockType(st.block_type);
			}

			if (st.dpi_fingerprint && Array.isArray(st.dpi_fingerprint.vulns) && st.dpi_fingerprint.vulns.length > 0) {
				dpiFingerprintBadgesEl.innerHTML = '';
				var badgeColors = {
					geneva: '#00d1b2',
					hostfake: '#61afef',
					seqovl: '#e5c07b',
					multidisorder: '#c678dd',
					fake: '#98c379',
					oob: '#e06c75',
					syndata: '#d19a66',
					wssize: '#56b6c2',
					multisplit: '#4fa6ed'
				};
				st.dpi_fingerprint.vulns.forEach(function(v) {
					var label = (st.dpi_fingerprint.labels && st.dpi_fingerprint.labels[v]) || v;
					var color = badgeColors[v] || '#00d1b2';
					dpiFingerprintBadgesEl.appendChild(E('span', {
						class: 'badge',
						style: 'background: rgba(255,255,255,0.06); border: 1px solid ' + color + '; color: ' + color + '; font-size: 11px; padding: 2px 7px; border-radius: 4px; font-weight: 600;'
					}, '✓ ' + label));
				});
			}

			if (activeLogTab === 'scanner' && st.log) {
				consoleLogEl.textContent = st.log;
				if (autoLogScroll) consoleLogEl.scrollTop = consoleLogEl.scrollHeight;
			}

			if (st.circular && st.circular.trim() !== '') {
				lastCircular = st.circular;
			}

			if (st.strategies && st.strategies.length > 0) {
				lastResults = st.strategies;
				renderStrategyCards(st.strategies);
			}
		}

		function renderStrategyCards(strategies) {
			resultsCard.style.display = 'block';
			strategiesListEl.innerHTML = '';

			// Deduplicate strategies and collect supported protocols
			var uniqueStrats = [];
			var seen = {};

			(strategies || []).forEach(function(strat) {
				var sText = (typeof strat === 'string') ? strat : (strat.args || JSON.stringify(strat));
				if (!sText || sText.trim() === '') return;
				sText = sText.trim();

				if (!seen[sText]) {
					var item = {
						args: sText,
						protocols: []
					};
					if (typeof strat === 'object') {
						if (Array.isArray(strat.protocols)) {
							item.protocols = strat.protocols.slice();
						} else if (strat.protocol) {
							item.protocols.push(strat.protocol.replace(/^HTTPS\//, ''));
						}
					}
					seen[sText] = item;
					uniqueStrats.push(item);
				} else {
					if (typeof strat === 'object') {
						var toAdd = [];
						if (Array.isArray(strat.protocols)) {
							toAdd = strat.protocols;
						} else if (strat.protocol) {
							toAdd = [strat.protocol.replace(/^HTTPS\//, '')];
						}
						toAdd.forEach(function(p) {
							if (seen[sText].protocols.indexOf(p) === -1) {
								seen[sText].protocols.push(p);
							}
						});
					}
				}
			});

			uniqueStrategiesCount = uniqueStrats.length;
			var resultsTitle = resultsCard.querySelector('.bcw-card-title');
			if (resultsTitle) {
				resultsTitle.textContent = 'Найденные рабочие стратегии (' + uniqueStrategiesCount + ' уникальных, 100% проверено)';
			}
			var badgeEl = resultsCard.querySelector('.bcw-strats-count-badge');
			if (badgeEl) {
				badgeEl.textContent = uniqueStrategiesCount + ' шт.';
			}
			updateSpoilerUI();

			uniqueStrats.forEach(function(strat, idx) {
				var sText = strat.args;
				var protoBadgeText = '';
				if (strat.protocols && strat.protocols.length > 0) {
					protoBadgeText = strat.protocols.join(' + ');
				}

				var card = E('div', {
					class: 'bcw-strat-item',
					style: 'display: flex; flex-direction: column; gap: 8px; width: 100%; box-sizing: border-box;'
				}, [
					E('div', { class: 'bcw-strat-header', style: 'display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px;' }, [
						E('div', { style: 'display: flex; align-items: center; gap: 8px; flex-wrap: wrap;' }, [
							E('span', { class: 'badge cbi-color-green', style: 'font-weight: bold;' }, '#' + (idx + 1) + ' 100% Работает'),
							protoBadgeText ? E('span', { class: 'badge cbi-color-blue', style: 'font-weight: 600;' }, '🌐 ' + protoBadgeText) : '',
							E('strong', { style: 'color: #61afef; font-size: 12.5px;' }, 'Одиночная стратегия')
						]),
						E('button', {
							class: 'bcw-btn-sm cbi-button cbi-button-positive bcw-strat-apply-btn',
							style: 'height: 32px; padding: 0 14px; font-weight: bold; font-size: 12px; display: inline-flex; align-items: center; justify-content: center; gap: 4px;',
							click: function() { applyStrategy(sText, false); }
						}, '✓ Применить в Zapret2')
					]),
					E('pre', {
						class: 'bcw-code-box',
						style: 'max-height: 140px;'
					}, sText)
				]);
				strategiesListEl.appendChild(card);
			});
		}

		function applyStrategy(scriptText, isCirc) {
			bcwShowModal('Применение стратегии', [
				E('p', { class: 'spinning' }, 'Запись в конфигурацию Zapret2 и перезапуск службы...')
			]);

			fs.write('/tmp/blockcheckw_apply_temp.txt', scriptText).then(function() {
				return fs.exec(HELPER_BIN, ['apply', '--target', currentTarget, '--file', '/tmp/blockcheckw_apply_temp.txt']);
			}).then(function(res) {
				ui.hideModal();
				var parsed = null;
				try {
					parsed = JSON.parse(res.stdout);
				} catch(e) {}

				if (parsed && parsed.success) {
					var secName = parsed.section || 'новая запись';
					getZapretInfo().then(function(info) {
						zapretServicesData = info.services || {};
						zapretAllStrategies = info.all_strategies || [];
						updateSummaryBox();
						updateActiveStrategyDisplay();
						if (zapretBadgeEl) {
							zapretBadgeEl.className = 'bcw-header-item ' + ((info.zapret2_running === 'running') ? 'badge cbi-color-green' : 'badge cbi-color-red');
							zapretBadgeEl.textContent = (info.zapret2_running === 'running') ? '✓ Zapret2Wizard активен' : '✗ Zapret2Wizard остановлен';
						}
					});
					refreshLogs();
					lastAppliedResult = parsed;

					showStrategyAppliedModal({
						section: secName,
						isAuto: false,
						applyResult: parsed,
						connected: parsed.connected,
						httpCode: parsed.http_code
					});
				} else {
					ui.addNotification(null, E('p', {}, 'Ошибка применения: ' + (parsed ? parsed.error : res.stderr)), 'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Ошибка применения: ' + err), 'danger');
			});
		}

		function testActiveConnection() {
			var pDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'];
			var url = pDef.test_url || 'https://rutracker.org';
			if (currentTarget === 'domains') {
				var d = customDomainInput.value.trim();
				if (d) {
					if (!/^https?:\/\//i.test(d)) d = 'https://' + d;
					url = d;
				}
			} else if (currentTarget === 'test_strategy') {
				var u = testUrlInput.value.trim();
				if (u) {
					if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
					url = u;
				}
			}

			var chosenStratName = (currentTarget === 'test_strategy') ? testStrategySelectEl.value : null;
			var stratObj = chosenStratName ? zapretAllStrategies.find(function(s) { return s.section === chosenStratName; }) : null;

			bcwShowModal('Комплексная проверка доступности', [
				E('p', { class: 'spinning' }, 'Отправка проверочных сетевых запросов и замер передачи данных к ' + (pDef.label || currentTarget) + '...')
			]);

			fs.exec(HELPER_BIN, ['test', currentTarget, url]).then(function(res) {
				ui.hideModal();
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				if (!parsed) {
					ui.addNotification(null, E('p', {}, 'Не удалось проанализировать ответ проверки.'), 'danger');
					return;
				}

				var isAllOk = parsed.all_ok === true;
				var isAccessible = parsed.accessible === true;
				var statusType = parsed.overall_status || (isAllOk ? 'optimal' : isAccessible ? 'degraded' : 'blocked');

				var bannerColor = (statusType === 'optimal') ? '#00d1b2' :
				                  (statusType === 'degraded') ? '#f59e0b' : '#ef4444';
				var bannerBg = (statusType === 'optimal') ? 'rgba(0, 209, 178, 0.12)' :
				               (statusType === 'degraded') ? 'rgba(245, 158, 11, 0.12)' : 'rgba(239, 68, 68, 0.12)';
				var bannerIcon = (statusType === 'optimal') ? '🟢' :
				                 (statusType === 'degraded') ? '🟡' : '🔴';
				var bannerTitle = (statusType === 'optimal') ? '100% сервиса доступно (Данные передаются без помех)' :
				                  (statusType === 'degraded') ? 'Частичная доступность (Основной сайт отвечает, но часть потоков блокируется)' :
				                  'Сервис заблокирован ТСПУ или недоступен';

				var rows = [];
				if (parsed.endpoints && Array.isArray(parsed.endpoints)) {
					parsed.endpoints.forEach(function(ep) {
						var epOk = ep.accessible === true;
						var speedText = ep.speed_kbs > 1024 ? ((ep.speed_kbs / 1024).toFixed(1) + ' МБ/с') : (ep.speed_kbs + ' КБ/с');
						rows.push(E('div', {
							style: 'display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; background: rgba(0,0,0,0.2); border-radius: 6px; margin-bottom: 6px; font-size: 13px; flex-wrap: wrap; gap: 8px;'
						}, [
							E('div', { style: 'display: flex; flex-direction: column; gap: 2px;' }, [
								E('strong', { style: 'color: #e5e9f0;' }, ep.name),
								E('span', { style: 'font-size: 11px; color: #abb2bf;' }, ep.url)
							]),
							E('div', { style: 'display: flex; align-items: center; gap: 8px;' }, [
								epOk ? E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, '✓ HTTP ' + ep.http_code) :
								       (ep.truncated ? E('span', { class: 'badge cbi-color-amber', style: 'font-size: 11px; background: #d19a66; color: #000; font-weight: bold;' }, '⚠️ Обрыв ТСПУ (0 Б)') :
								                       E('span', { class: 'badge cbi-color-red', style: 'font-size: 11px;' }, '✗ Код ' + ep.http_code)),
								ep.size_bytes > 0 ? E('span', { style: 'font-size: 11px; color: #61afef; font-weight: bold;' }, '⚡ ' + speedText) : null,
								ep.time_sec ? E('span', { style: 'font-size: 11px; color: #5c6370;' }, ep.time_sec + 'с') : null
							].filter(Boolean))
						]));
					});
				}

				var modalBody = [
					E('div', {
						style: 'background: ' + bannerBg + '; border: 1.5px solid ' + bannerColor + '; border-radius: 8px; padding: 12px 16px; margin-bottom: 14px;'
					}, [
						E('div', { style: 'display: flex; align-items: center; gap: 8px; font-weight: bold; font-size: 14px; color: ' + bannerColor + ';' }, [
							E('span', { style: 'font-size: 20px;' }, bannerIcon),
							E('span', {}, bannerTitle)
						]),
						E('p', { style: 'margin: 6px 0 0 0; font-size: 12px; color: #e5e9f0; line-height: 1.4;' }, parsed.message)
					]),
					E('div', { style: 'margin-bottom: 12px; font-weight: bold; color: #61afef; font-size: 13px;' }, '🌐 Проверенные эндпоинты и передача данных:'),
					E('div', { style: 'max-height: 240px; overflow-y: auto; margin-bottom: 14px;' }, rows),
					stratObj && !stratObj.enabled ? E('div', {
						style: 'padding: 8px 12px; background: rgba(229, 192, 123, 0.15); border-left: 3px solid #e5c07b; border-radius: 4px; font-size: 12px; color: #e5c07b; margin-bottom: 10px;'
					}, '⚠️ Внимание: стратегия zapret2.' + stratObj.section + ' сейчас отключена в Zapret2, трафик идет без неё.') : null
				].filter(Boolean);

				var modalButtons = [
					E('button', {
						class: 'cbi-button cbi-button-neutral',
						style: 'padding: 6px 16px; font-size: 13px;',
						click: function() { ui.hideModal(); }
					}, 'Закрыть')
				];

				if (!isAllOk) {
					modalButtons.push(E('button', {
						class: 'cbi-button cbi-button-action',
						style: 'padding: 6px 16px; font-size: 13px; font-weight: bold;',
						click: function() {
							ui.hideModal();
							startScan();
						}
					}, '⚡ Запустить поиск рабочей стратегии'));
				}

				bcwShowModal('Результаты проверки: ' + (pDef.label || currentTarget), modalBody, modalButtons);
			}).catch(function() {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Не удалось выполнить комплексную сетевую проверку.'), 'danger');
			});
		}

		function runSpeedTest() {
			var pDef = PRESET_DEFS[currentTarget] || PRESET_DEFS['builtin'] || {};
			var url = pDef.test_url || 'https://www.youtube.com';
			if (currentTarget === 'domains') {
				var d = customDomainInput.value.trim();
				if (d) {
					if (!/^https?:\/\//i.test(d)) d = 'https://' + d;
					url = d;
				}
			} else if (currentTarget === 'test_strategy') {
				var u = testUrlInput.value.trim();
				if (u) {
					if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
					url = u;
				}
			}

			bcwShowModal('⚡ Замер реальной скорости видео и проверка DPI', [
				E('div', { style: 'text-align: center; padding: 18px 10px;' }, [
					E('p', { class: 'spinning', style: 'font-size: 15px; font-weight: bold; color: #61afef;' },
						'Тестирование пропускной способности видеопотока к ' + (pDef.name || currentTarget) + '...'),
					E('p', { style: 'font-size: 12px; color: #abb2bf; margin-top: 6px;' },
						'Загрузка тестового 2 МБ медиа-сегмента через активную стратегию Zapret2, вычисление задержки и анализ DPI-троттлинга...')
				])
			]);

			fs.exec(HELPER_BIN, ['speedtest', currentTarget, url]).then(function(res) {
				ui.hideModal();
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				if (!parsed) {
					ui.addNotification(null, E('p', {}, 'Не удалось проанализировать ответ замера скорости.'), 'danger');
					return;
				}

				var isThrottled = parsed.throttled === true;
				var isSuccess = parsed.success === true;
				var badgeColor = isThrottled ? '#ef4444' : (parsed.rating_badge === 'cbi-color-green' ? '#00d1b2' : '#f59e0b');
				var bannerBg = isThrottled ? 'rgba(239, 68, 68, 0.12)' : (parsed.rating_badge === 'cbi-color-green' ? 'rgba(0, 209, 178, 0.12)' : 'rgba(245, 158, 11, 0.12)');
				var icon = isThrottled ? '🔴' : (parsed.rating === '4k' ? '🚀' : parsed.rating === '2k' ? '🟢' : '🟡');

				var speedVal = parsed.speed_mbs > 0 ? (parsed.speed_mbs + ' МБ/с') : (parsed.speed_kbs + ' КБ/с');
				var speedMbps = parsed.speed_mbps ? (parsed.speed_mbps + ' Мбит/с') : '';

				var modalBody = [
					E('div', {
						style: 'background: ' + bannerBg + '; border: 1.5px solid ' + badgeColor + '; border-radius: 8px; padding: 16px; margin-bottom: 16px; text-align: center;'
					}, [
						E('div', { style: 'font-size: 12px; text-transform: uppercase; letter-spacing: 1px; color: #abb2bf; font-weight: 600;' }, 'Реальная скорость видеопотока'),
						E('div', { style: 'font-size: 32px; font-weight: 900; color: ' + badgeColor + '; margin: 6px 0;' }, speedVal),
						speedMbps ? E('div', { style: 'font-size: 14px; color: #abb2bf; font-weight: 600;' }, '≈ ' + speedMbps) : null,
						E('div', { style: 'display: inline-flex; align-items: center; gap: 6px; margin-top: 10px; padding: 4px 14px; border-radius: 20px; background: rgba(0,0,0,0.25); font-weight: bold; font-size: 13px; color: ' + badgeColor + ';' }, [
							E('span', {}, icon),
							E('span', {}, parsed.rating_title || parsed.rating)
						])
					].filter(Boolean)),

					E('div', {
						style: 'display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-bottom: 16px;'
					}, [
						E('div', { style: 'background: rgba(0,0,0,0.2); border-radius: 6px; padding: 10px; text-align: center;' }, [
							E('div', { style: 'font-size: 11px; color: #abb2bf;' }, 'Пинг до CDN'),
							E('div', { style: 'font-size: 15px; font-weight: bold; color: #e5e9f0; margin-top: 4px;' }, (parsed.latency_ms || 0) + ' мс')
						]),
						E('div', { style: 'background: rgba(0,0,0,0.2); border-radius: 6px; padding: 10px; text-align: center;' }, [
							E('div', { style: 'font-size: 11px; color: #abb2bf;' }, 'Время отклика (TTFB)'),
							E('div', { style: 'font-size: 15px; font-weight: bold; color: #e5e9f0; margin-top: 4px;' }, (parsed.ttfb_ms || 0) + ' мс')
						]),
						E('div', { style: 'background: rgba(0,0,0,0.2); border-radius: 6px; padding: 10px; text-align: center;' }, [
							E('div', { style: 'font-size: 11px; color: #abb2bf;' }, 'Объем теста'),
							E('div', { style: 'font-size: 15px; font-weight: bold; color: #e5e9f0; margin-top: 4px;' }, (parsed.size_mb || '0') + ' МБ за ' + (parsed.total_time_sec || '0') + 'с')
						])
					]),

					parsed.ggc_mapping ? E('div', {
						style: 'background: rgba(0,0,0,0.25); border: 1px solid var(--bcw-border-sub); border-radius: 6px; padding: 10px 14px; margin-bottom: 14px; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px;'
					}, [
						E('div', { style: 'display: flex; align-items: center; gap: 10px;' }, [
							E('span', { style: 'font-size: 18px;' }, '🌐'),
							E('div', {}, [
								E('div', { style: 'font-size: 11px; color: #abb2bf;' }, 'Маршрутизация Google Global Cache (GGC):'),
								E('div', { style: 'font-size: 13px; font-weight: bold; color: #e5e9f0;' },
									(parsed.ggc_mapping.cluster || 'Неизвестен') + ' (' + (parsed.ggc_mapping.operator || 'Google CDN') + ' • ' + (parsed.ggc_mapping.city || 'Регион') + ')')
							])
						]),
						E('span', {
							class: 'badge ' + (parsed.ggc_mapping.is_local ? 'cbi-color-green' : 'cbi-color-amber'),
							style: 'font-size: 11px; padding: 4px 10px; font-weight: 600;'
						}, parsed.ggc_mapping.is_local ? '✓ Локальный узел РФ' : '⚠️ Резервный ЦОД (Европа)')
					]) : null,

					E('div', {
						style: 'padding: 12px 14px; background: rgba(0,0,0,0.2); border-left: 3px solid ' + badgeColor + '; border-radius: 6px; font-size: 13px; line-height: 1.5; color: #e5e9f0; margin-bottom: 14px;'
					}, [
						E('strong', { style: 'display: block; margin-bottom: 4px; color: ' + badgeColor + ';' },
							isThrottled ? '⚠️ Анализ троттлинга ТСПУ:' : '✓ Анализ качества:'),
						E('span', {}, parsed.verdict || '')
					]),

					E('div', { style: 'font-size: 11px; color: #5c6370; text-align: center;' },
						'Тестовый узел: ' + (parsed.test_name || '') + ' (' + (parsed.test_endpoint || '') + ')')
				].filter(Boolean);

				var modalButtons = [
					E('button', {
						class: 'cbi-button cbi-button-neutral',
						style: 'padding: 6px 16px;',
						click: function() { ui.hideModal(); }
					}, 'Закрыть'),
					E('button', {
						class: 'cbi-button cbi-button-neutral',
						style: 'padding: 6px 16px; margin-left: 8px;',
						click: function() { runSpeedTest(); }
					}, '🔄 Повторить замер')
				];

				if (isThrottled || !isSuccess) {
					modalButtons.push(E('button', {
						class: 'cbi-button cbi-button-action',
						style: 'background: #00d1b2; color: #081a17; font-weight: bold; padding: 6px 18px; margin-left: 8px;',
						click: function() {
							ui.hideModal();
							startScan();
						}
					}, '⚡ Запустить подбор рабочей стратегии'));
				}

				bcwShowModal('Результаты замера скорости: ' + (pDef.name || currentTarget), modalBody, modalButtons);
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Ошибка при выполнении замера скорости: ' + err), 'danger');
			});
		}

		function formatChangelogList(changelog) {
			var items = [];
			if (Array.isArray(changelog)) {
				items = changelog;
			} else if (typeof changelog === 'string' && changelog.trim()) {
				if (changelog.indexOf('\n') !== -1) {
					items = changelog.split('\n');
				} else if (changelog.indexOf(';') !== -1) {
					items = changelog.split(';');
				} else if (changelog.indexOf('•') !== -1) {
					items = changelog.split('•');
				} else {
					items = [changelog];
				}
			}

			items = items.map(function(s) {
				return (typeof s === 'string') ? s.replace(/^[-*•\s]+/, '').trim() : '';
			}).filter(function(s) {
				return s.length > 0;
			});

			if (items.length === 0) {
				return [E('li', { style: 'color: #abb2bf; font-size: 13px;' }, 'Улучшения стабильности и оптимизация работы службы.')];
			}

			return items.map(function(item) {
				return E('li', {
					style: 'margin-bottom: 8px; color: #e5e9f0; line-height: 1.45; font-size: 13px; display: flex; align-items: flex-start; gap: 8px;'
				}, [
					E('span', { style: 'color: #00d1b2; font-weight: bold; flex-shrink: 0;' }, '✓'),
					E('span', {}, item)
				]);
			});
		}

		function showWhatsNewModal(info, isPostUpdate) {
			var ver = info.current_version || '0.15.1';
			var date = info.current_release_date || info.release_date || '31.10.2026';
			var list = formatChangelogList(info.current_changelog || info.changelog);
			var title = isPostUpdate ? ('🎉 Служба успешно обновлена до v' + ver + '!') : ('Что нового в Zapret2Wizard v' + ver);

			bcwShowModal(title, [
				E('div', { style: 'border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px; margin-bottom: 14px;' }, [
					E('div', { style: 'font-size: 16px; font-weight: bold; color: #00d1b2; display: flex; align-items: center; gap: 8px;' }, [
						isPostUpdate ? '🚀 Обновление успешно установлено' : ('🎉 Релиз v' + ver),
						E('span', { class: 'badge cbi-color-green', style: 'font-size: 11px;' }, 'v' + ver)
					]),
					E('div', { style: 'font-size: 12px; color: #abb2bf; margin-top: 4px;' }, 'Дата релиза: ' + date + ' • Репозиторий: ' + (info.repo || 'prostoy23rus/zapret2wizard') + ' (ветка main)')
				]),
				E('div', { style: 'font-size: 14px; font-weight: bold; color: #61afef; margin-bottom: 8px;' }, '📋 Список внесённых изменений и нововведений:'),
				E('ul', { style: 'list-style: none; padding: 12px 14px; margin: 0 0 16px 0; max-height: 320px; overflow-y: auto; background: rgba(0,0,0,0.25); border-radius: 6px; border: 1px solid #383e4a;' }, list),
				E('div', { style: 'background: rgba(0, 209, 178, 0.06); border: 1px solid rgba(0, 209, 178, 0.2); border-radius: 6px; padding: 10px 14px; font-size: 12px; color: #abb2bf;' }, [
					E('strong', { style: 'color: #00d1b2;' }, '🛡️ Защита настроек: '),
					'Все ваши настроенные стратегии в Zapret2 сохранены и продолжают работать в штатном режиме.'
				])
			], [
				E('button', {
					class: 'cbi-button cbi-button-action',
					style: 'padding: 6px 18px; font-size: 13px; font-weight: bold;',
					click: function() { ui.hideModal(); }
				}, '👍 Отлично, понятно')
			]);
		}

		var updateCheckStatus = {
			checked: false,
			has_update: false,
			latest_version: curVer
		};

		function confirmRunUpdate(targetVer) {
			bcwShowModal('Обновление службы Zapret2Wizard', [
				E('div', { style: 'margin-bottom: 14px;' }, [
					E('div', { style: 'font-size: 16px; font-weight: bold; color: #00d1b2; display: flex; align-items: center; gap: 8px;' }, [
						'🚀 Доступна новая версия: v' + targetVer,
						E('span', { class: 'badge cbi-color-blue', style: 'font-size: 11px;' }, 'v' + curVer + ' ➔ v' + targetVer)
					]),
					E('p', { style: 'margin-top: 10px; color: #e5e9f0; line-height: 1.5;' },
						'Обновить службу Zapret2Wizard до версии v' + targetVer + ' прямо сейчас? Все настроенные стратегии в Zapret2 будут сохранены.'
					)
				])
			], [
				E('button', {
					class: 'cbi-button',
					click: function() { ui.hideModal(); }
				}, 'Отмена'),
				E('button', {
					class: 'cbi-button cbi-button-action',
					style: 'font-weight: bold;',
					click: function() {
						ui.hideModal();
						doRunUpdate(targetVer);
					}
				}, '🚀 Установить обновление v' + targetVer)
			]);
		}

		function showUpdateBanner(info) {
			updateBannerCard.innerHTML = '';
			var nextVer = info.latest_version || 'новой версии';
			var releaseDate = info.release_date ? ' (' + info.release_date + ')' : '';
			var repoName = info.repo || 'prostoy23rus/zapret2wizard';

			var changelogNodes = [];
			var rawList = info.changelog || [];
			if (Array.isArray(rawList) && rawList.length > 0) {
				var displayItems = rawList.slice(0, 3);
				var ul = E('ul', { style: 'list-style: none; padding: 6px 0 0 0; margin: 8px 0 0 0; font-size: 12.5px; color: #abb2bf; display: flex; flex-direction: column; gap: 4px;' });
				displayItems.forEach(function(item) {
					ul.appendChild(E('li', { style: 'display: flex; gap: 6px; align-items: flex-start;' }, [
						E('span', { style: 'color: #00d1b2; font-weight: bold;' }, '•'),
						E('span', {}, item)
					]));
				});
				if (rawList.length > 3) {
					ul.appendChild(E('li', { style: 'color: #61afef; font-size: 11px; margin-top: 2px;' }, '+ ещё ' + (rawList.length - 3) + ' улучшений...'));
				}
				changelogNodes.push(ul);
			}

			updateBannerCard.appendChild(E('div', {
				style: 'display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 14px;'
			}, [
				E('div', { style: 'flex: 1 1 auto; min-width: 0;' }, [
					E('div', { style: 'font-size: 15px; font-weight: bold; color: #00d1b2; display: flex; align-items: center; gap: 8px;' }, [
						'🎉 Доступна новая версия: v' + nextVer,
						E('span', { style: 'font-size: 12px; font-weight: normal; color: #828997;' }, releaseDate)
					]),
					E('div', { style: 'font-size: 13px; color: #e5e9f0; margin-top: 4px;' }, 'Обнаружена новая версия службы с оптимизацией обхода и точным поиском:'),
					changelogNodes.length > 0 ? E('div', {}, changelogNodes) : null,
					E('div', { style: 'font-size: 11px; color: #abb2bf; margin-top: 6px;' }, 'Репозиторий: ' + repoName + ' (ветка main)')
				].filter(Boolean)),
				E('div', { style: 'display: flex; gap: 10px; align-items: center;' }, [
					E('button', {
						class: 'bcw-btn-launch',
						style: 'padding: 8px 18px; font-size: 13px;',
						click: function() { doRunUpdate(nextVer); }
					}, '🚀 Обновить до v' + nextVer),
					E('button', {
						class: 'bcw-btn-secondary',
						style: 'padding: 8px 14px; font-size: 13px;',
						click: function() { updateBannerCard.style.display = 'none'; }
					}, 'Скрыть')
				])
			]));
			updateBannerCard.style.display = 'block';
		}

		function applyUpdateResult(parsed, isManual) {
			updateCheckStatus.checked = true;
			if (!parsed || !parsed.success) {
				btnCheckUpdate.innerHTML = '';
				btnCheckUpdate.appendChild(E('span', {}, '🔄'));
				btnCheckUpdate.appendChild(document.createTextNode(' Проверить обновление (v' + curVer + ')'));
				btnCheckUpdate.title = 'Не удалось проверить автоматически. Нажмите для повторной проверки';
				btnCheckUpdate.style.borderColor = '#485060';
				btnCheckUpdate.style.background = '#282c34';
				btnCheckUpdate.style.color = '#abb2bf';
				if (isManual) {
					ui.addNotification(null, E('p', {}, 'Не удалось связаться с GitHub: ' + (parsed && parsed.error ? parsed.error : 'ошибка сети')), 'warning');
				}
				return;
			}

			if (parsed.has_update) {
				updateCheckStatus.has_update = true;
				updateCheckStatus.latest_version = parsed.latest_version;
				btnCheckUpdate.innerHTML = '';
				btnCheckUpdate.appendChild(E('span', { style: 'color: #61afef;' }, '🚀'));
				btnCheckUpdate.appendChild(document.createTextNode(' Доступно обновление: v' + parsed.latest_version));
				btnCheckUpdate.title = 'Доступна новая версия v' + parsed.latest_version + '. Нажмите для установки в 1 клик';
				btnCheckUpdate.style.borderColor = '#3273dc';
				btnCheckUpdate.style.background = 'rgba(50, 115, 220, 0.2)';
				btnCheckUpdate.style.color = '#ffffff';

				showUpdateBanner(parsed);
			} else {
				updateCheckStatus.has_update = false;
				updateCheckStatus.latest_version = parsed.current_version || curVer;
				btnCheckUpdate.innerHTML = '';
				btnCheckUpdate.appendChild(E('span', { style: 'color: #00d1b2; font-weight: bold;' }, '✓'));
				btnCheckUpdate.appendChild(document.createTextNode(' Стоит последняя версия (v' + (parsed.current_version || curVer) + ')'));
				btnCheckUpdate.title = 'У вас установлена последняя актуальная версия. Нажмите для повторной проверки';
				btnCheckUpdate.style.borderColor = 'rgba(0, 209, 178, 0.4)';
				btnCheckUpdate.style.background = 'rgba(0, 209, 178, 0.08)';
				btnCheckUpdate.style.color = '#e5e9f0';

				updateBannerCard.style.display = 'none';

				if (isManual) {
					ui.addNotification(null, E('p', {}, '✓ У вас установлена последняя версия Zapret2Wizard (v' + (parsed.current_version || curVer) + '). Обновлений не требуется.'), 'info');
				}
			}
		}

		function doCheckUpdate(isManual) {
			if (isManual) {
				btnCheckUpdate.innerHTML = '';
				btnCheckUpdate.appendChild(E('span', {}, '🔄'));
				btnCheckUpdate.appendChild(document.createTextNode(' Проверка...'));
			}

			fs.exec(HELPER_BIN, ['check_update']).then(function(res) {
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				applyUpdateResult(parsed, isManual);
			}).catch(function(err) {
				applyUpdateResult({ success: false, error: err }, isManual);
			});
		}
		function doRunUpdate(targetVer) {
			bcwShowModal('Обновление службы Zapret2Wizard', [
				E('p', { class: 'spinning', style: 'font-size: 14px; font-weight: bold;' }, 'Загрузка свежих файлов из GitHub и обновление...'),
				E('div', { style: 'font-size: 12px; color: #abb2bf; margin-top: 10px; line-height: 1.6;' }, [
					'1. Загрузка обновленного скрипта управления и LuCI интерфейса',
					E('br'),
					'2. Обновление базы пресетов Zapret2 и генератора связок',
					E('br'),
					'3. Сброс кэша интерфейса LuCI и перезапуск службы rpcd'
				])
			]);

			fs.exec(HELPER_BIN, ['update']).then(function(res) {
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}

				if (parsed && parsed.success) {
					try {
						localStorage.setItem('bcw_just_updated', '1');
					} catch(e) {}

					bcwShowModal('Обновление успешно выполнено', [
						E('p', { class: 'cbi-color-green', style: 'font-size: 16px; font-weight: bold;' }, '✓ ' + (parsed.message || 'Служба успешно обновлена!')),
						E('p', { style: 'margin-top: 8px;' }, 'Интерфейс автоматически перезагрузится через 2 секунды...')
					], [
						E('button', {
							class: 'btn cbi-button-action',
							click: function() { location.reload(); }
						}, 'Перезагрузить сейчас')
					]);
					setTimeout(function() {
						location.reload();
					}, 2000);
				} else {
					bcwShowModal('Ошибка обновления', [
						E('p', { class: 'cbi-color-red', style: 'font-weight: bold; font-size: 14px;' }, '✗ Не удалось обновить компоненты:'),
						E('pre', { class: 'bcw-code-box', style: 'color: #e06c75; margin: 10px 0;' }, parsed && parsed.error ? parsed.error : (res.stderr || res.stdout || 'Неизвестная ошибка')),
						E('p', { style: 'font-size: 12px; color: #abb2bf; margin-top: 8px;' }, '💡 Вы также можете обновить службу вручную через терминал роутера командой:'),
						E('code', { style: 'display: block; background: #1c2027; padding: 6px 10px; border-radius: 4px; color: #61afef; font-size: 12px; margin-top: 4px;' }, 'blockcheckw-helper update')
					], [
						E('button', {
							class: 'cbi-button cbi-button-neutral',
							style: 'padding: 6px 18px;',
							click: function() { ui.hideModal(); }
						}, 'Закрыть')
					]);
				}
			}).catch(function(err) {
				bcwShowModal('Ошибка сети', [
					E('p', { class: 'cbi-color-red', style: 'font-weight: bold; font-size: 14px;' }, '✗ Сбой при выполнении команды обновления:'),
					E('pre', { class: 'bcw-code-box', style: 'color: #e06c75; margin: 10px 0;' }, String(err))
				], [
					E('button', {
						class: 'cbi-button cbi-button-neutral',
						style: 'padding: 6px 18px;',
						click: function() { ui.hideModal(); }
					}, 'Закрыть')
				]);
			});
		}

		function showHostlistsModal(hostlists) {
			var lists = hostlists || zapretInfo.hostlists || [];
			var rows = [];

			if (!lists || lists.length === 0) {
				lists = [
					{ key: 'youtube', name: 'YouTube', file: '/opt/zapret2/ipset/zapret_hosts_youtube.txt', domains_count: 9, uci_configured: true },
					{ key: 'discord', name: 'Discord', file: '/opt/zapret2/ipset/zapret_hosts_discord.txt', domains_count: 9, uci_configured: true },
					{ key: 'x', name: 'X (Twitter)', file: '/opt/zapret2/ipset/zapret_hosts_x.txt', domains_count: 10, uci_configured: true },
					{ key: 'instagram', name: 'Instagram', file: '/opt/zapret2/ipset/zapret_hosts_instagram.txt', domains_count: 9, uci_configured: true },
					{ key: 'twitch', name: 'Twitch', file: '/opt/zapret2/ipset/zapret_hosts_twitch.txt', domains_count: 6, uci_configured: true },
					{ key: 'user', name: 'Общие сайты (User)', file: '/opt/zapret2/ipset/zapret_hosts_user.txt', domains_count: 33, uci_configured: true }
				];
			}

			lists.forEach(function(hl) {
				var countText = (hl.domains_count || 0) + ' доменов';
				var isOk = (hl.domains_count > 0 && hl.uci_configured);
				rows.push(E('div', {
					style: 'display: flex; align-items: center; justify-content: space-between; padding: 10px 14px; background: rgba(255,255,255,0.03); border: 1px solid #383e4a; border-radius: 6px; margin-bottom: 8px;'
				}, [
					E('div', {}, [
						E('div', { style: 'font-weight: bold; color: #e5e9f0; font-size: 13px; display: flex; align-items: center; gap: 6px;' }, [
							E('span', { style: 'color: ' + (isOk ? '#98c379' : '#e5c07b') }, isOk ? '✓' : '⚠️'),
							hl.name
						]),
						E('div', { style: 'font-size: 11.5px; color: #abb2bf; font-family: monospace; margin-top: 3px;' }, hl.file)
					]),
					E('div', { style: 'text-align: right;' }, [
						E('div', { style: 'font-weight: bold; color: ' + (hl.domains_count > 0 ? '#98c379' : '#e06c75') + '; font-size: 13px;' },
							countText
						),
						E('div', { style: 'font-size: 11px; color: ' + (hl.uci_configured ? '#61afef' : '#e5c07b') + ';' },
							hl.uci_configured ? 'Zapret2 подключен' : 'Секция создается...'
						)
					])
				]));
			});

			var statusContainer = E('div', { id: 'bcw-hostlists-container' }, rows);

			var refreshBtn = E('button', {
				class: 'bcw-btn-launch',
				style: 'height: 38px; font-size: 13px;',
				click: function() {
					var self = this;
					self.disabled = true;
					self.textContent = '⏳ Проверка и восстановление...';
					fs.exec(HELPER_BIN, ['ensure_hostlists']).then(function(res) {
						return getZapretInfo();
					}).then(function(info) {
						zapretInfo = info || {};
						showHostlistsModal(zapretInfo.hostlists);
						ui.addNotification(null, E('p', {}, '✓ Все списки доменов проверены и синхронизированы с Zapret2!'), 'info');
					}).catch(function(err) {
						self.disabled = false;
						self.textContent = '🔄 Повторить проверку';
						ui.addNotification(null, E('p', {}, 'Ошибка проверки: ' + err), 'danger');
					});
				}
			}, [ '🔄 Проверить и восстановить сейчас' ]);

			var closeBtn = E('button', {
				class: 'bcw-btn-secondary',
				style: 'height: 38px; font-size: 13px;',
				click: function() { ui.hideModal(); }
			}, [ 'Закрыть' ]);

			bcwShowModal('📋 Изолированные списки доменов Zapret2', [
				E('div', { style: 'margin-bottom: 14px; font-size: 13px; color: #abb2bf; line-height: 1.5;' }, [
					'BlockcheckW автоматически поддерживает и восстанавливает отдельные списки доменов в ',
					E('code', { style: 'color: #98c379;' }, '/opt/zapret2/ipset/'),
					' при каждом открытии страницы и перед запуском сканирования. Ваши добавленные домены всегда сохраняются.'
				]),
				statusContainer
			], [ refreshBtn, closeBtn ]);
		}

		function confirmUninstall() {
			bcwShowModal('Удаление Zapret2Wizard с роутера', [
				E('p', { style: 'font-weight: bold; color: #ff3860; font-size: 14px;' }, '⚠️ Вы действительно хотите полностью удалить Zapret2Wizard с роутера?'),
				E('div', { style: 'margin: 12px 0; font-size: 13px; line-height: 1.5; color: #abb2bf;' }, [
					E('p', {}, 'Будут полностью удалены:'),
					E('ul', { style: 'margin-left: 20px; margin-top: 6px;' }, [
						E('li', {}, 'Исполняемый файл сканера /usr/bin/blockcheckw'),
						E('li', {}, 'Веб-интерфейс OpenWrt LuCI и пункт в меню служб'),
						E('li', {}, 'Вспомогательные скрипты и база пресетов'),
						E('li', {}, 'Временные файлы и кэш LuCI')
					]),
					E('p', { style: 'margin-top: 10px; color: #98c379;' }, '✓ Ваши сохранённые стратегии в Zapret2 продолжат работать без изменений.')
				])
			], [
				E('button', {
					class: 'cbi-button cbi-button-neutral',
					click: function() { ui.hideModal(); }
				}, 'Отмена'),
				E('button', {
					class: 'cbi-button cbi-button-negative',
					style: 'background: #e06c75; color: #fff; font-weight: bold;',
					click: function() {
						ui.hideModal();
						doUninstallService();
					}
				}, '🗑 Да, удалить Zapret2Wizard')
			]);
		}

		function doUninstallService() {
			bcwShowModal('Удаление службы...', [
				E('p', { class: 'spinning' }, 'Удаление файлов BlockcheckW и сброс кэша роутера...')
			]);

			fs.exec(HELPER_BIN, ['uninstall']).then(function(res) {
				var parsed = null;
				try { parsed = JSON.parse(res.stdout); } catch(e) {}
				if (parsed && parsed.success) {
					bcwShowModal('Удаление завершено', [
						E('p', { style: 'color: #00d1b2; font-weight: bold; font-size: 15px;' }, '✓ ' + (parsed.message || 'Zapret2Wizard успешно удалён с роутера!')),
						E('p', { style: 'font-size: 13px; margin-top: 8px;' }, 'Сейчас вы будете перенаправлены на главную страницу OpenWrt...')
					]);
					setTimeout(function() {
						window.location.href = L.url('admin/status/overview');
					}, 2500);
				} else {
					ui.hideModal();
					ui.addNotification(null, E('p', {}, 'Ошибка удаления: ' + (parsed ? parsed.error : res.stderr)), 'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, 'Ошибка удаления: ' + err), 'danger');
			});
		}

		// Check if the service was just updated and show friendly notification
		try {
			if (localStorage.getItem('bcw_just_updated') === '1') {
				localStorage.removeItem('bcw_just_updated');
				ui.addNotification(null, E('p', {}, '✓ Служба Zapret2Wizard успешно обновлена до актуальной версии!'), 'info');
			}
		} catch(e) {}

		// Show update banner if new version is already detected
		if (versionInfo && versionInfo.has_update) {
			showUpdateBanner(versionInfo);
		}

		// Fetch logs immediately in background so initial page render is instant
		setTimeout(function() {
			refreshLogs();
		}, 80);

		// Check for updates asynchronously without blocking page render
		setTimeout(function() {
			doCheckUpdate(false);
		}, 600);

		// Initial In-Memory Render
		updateSummaryBox();
		updateActiveStrategyDisplay();

		// Periodic background log refresher
		logPollInterval = setInterval(function() {
			if (!isRunning) {
				refreshLogs();
			}
		}, 5000);

		// Initial check if background scan is already running or has previous diagnosis
		if (statusData.status === 'running') {
			activeScanInProgress = true;
			monitorCard.style.display = 'block';
			btnStartScan.style.display = 'none';
			btnStopScan.style.display = 'inline-flex';
			updateProgressUI(statusData);
			startPolling();
		} else if (statusData.status === 'done' && (statusData.isp || statusData.block_type)) {
			monitorCard.style.display = 'block';
			updateProgressUI(statusData);
		}

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
