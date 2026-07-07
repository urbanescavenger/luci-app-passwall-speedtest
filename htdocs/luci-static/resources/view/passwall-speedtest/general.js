'use strict';
'require view';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';

const callStatus = rpc.declare({
	object: 'passwall-speedtest',
	method: 'status',
	expect: {}
});

const callStart = rpc.declare({
	object: 'passwall-speedtest',
	method: 'start',
	expect: {}
});

const callStop = rpc.declare({
	object: 'passwall-speedtest',
	method: 'stop',
	expect: {}
});

const callHistory = rpc.declare({
	object: 'passwall-speedtest',
	method: 'get_history',
	expect: { history: [] }
});

const callBestResult = rpc.declare({
	object: 'passwall-speedtest',
	method: 'get_best_result',
	expect: { content: '' }
});

const callListNodes = rpc.declare({
	object: 'passwall-speedtest',
	method: 'list_nodes',
	expect: {}
});

function script(src) {
	return new Promise(function(resolve, reject) {
		const existing = document.querySelector('script[src="%s"]'.format(src));

		if (existing && existing.dataset.loaded == 'true') {
			resolve();
			return;
		}

		const el = existing || E('script', { src: src });
		el.addEventListener('load', resolve, { once: true });
		el.addEventListener('error', reject, { once: true });
		el.onload = function() {
			el.dataset.loaded = 'true';
		};
		el.onerror = reject;

		if (!existing)
			document.head.appendChild(el);
	});
}

function chartCss() {
	return E('style', {}, `
.passwall-speedtest-chart-container {
	--card-bg: #f8f8f8;
	--text-color: #222;
	--card-shadow: 0 2px 6px rgba(0,0,0,0.1);
	width: 100%;
	margin: 20px auto;
	background: var(--card-bg);
	padding: 20px;
	border-radius: 8px;
	box-shadow: var(--card-shadow);
	color: var(--text-color);
	box-sizing: border-box;
}

@media (prefers-color-scheme: dark) {
	.passwall-speedtest-chart-container {
		--card-bg: #282828;
		--text-color: #e6eef6;
		--card-shadow: 0 2px 6px rgba(0,0,0,0.6);
	}
}

.passwall-speedtest-chart-container canvas {
	display: block;
	width: 100%;
	height: 300px;
}
`);
}

function tableCss() {
	return E('style', {}, `
/* CM IP lists / per-node IP list 两张 TableSection 表：单元格居中、控件字体匹配表格 */
.cbi-section table.table th,
.cbi-section table.table td {
	text-align: center;
	vertical-align: middle;
}
.cbi-section table.table td select,
.cbi-section table.table td input,
.cbi-section table.table td .cbi-input-multi,
.cbi-section table.table td .cbi-multi,
.cbi-section table.table td .cbi-value-field {
	font-size: 0.85em;
	margin: 0 auto;
	text-align: center;
}
`);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('passwall-speedtest'),
			callStatus(),
			callBestResult(),
			callHistory(),
			callListNodes()
		]);
	},

	updateStatus: function(node, status) {
		if (!node)
			return;

		const running = status && status.running;
		const cron = status && status.cron;

		node.replaceChildren(
			E('em', {}, [
				E('b', { style: 'color:%s'.format(running ? 'green' : 'red') },
					_('PassWall Speed Test') + ' ' + (running ? _('RUNNING') : _('NOT RUNNING')))
			]),
			' ',
			E('em', {}, [
				E('b', { style: 'color:%s'.format(cron ? 'green' : 'red') },
					cron ? _('Crontab enabled') : _('Crontab disabled'))
			])
		);
	},

	pollStatus: function(node, button) {
		return callStatus().then(L.bind(function(status) {
			const wasRunning = this._wasRunning;
			this._wasRunning = !!(status && status.running);
			this.updateStatus(node, status);
			this.updateButton(button, status && status.running);
			// 运行→停止跳变（点停止/定时任务跑完）时，重拉结果与历史并就地刷新，免手动刷新页面
			if (wasRunning && !this._wasRunning)
				return this.refreshResults();
		}, this));
	},

	// 重拉 Best IP 文本与历史图表，点停止/跑完后无需手动刷新页面即可看到新结果
	refreshResults: function() {
		return Promise.all([callBestResult(), callHistory()]).then(L.bind(function(res) {
			const best = res[0];
			const history = res[1] || [];
			const ta = document.getElementById('cbid.passwall-speedtest.global._best_result');
			if (ta)
				ta.value = (typeof best == 'string' ? best : (best && best.content) || '');
			const canvas = document.getElementById('passwall-speedtest-latency-chart');
			if (canvas && window.Chart) {
				const ex = Chart.getChart(canvas);
				if (ex) ex.destroy();
				this.drawCharts(canvas.closest('.passwall-speedtest-chart-container') || canvas.parentElement, history);
			}
		}, this)).catch(function() {});
	},

	updateButton: function(button, running) {
		if (!button)
			return;

		if (button.classList) {
			button.value = running ? _('Stop') : _('Start');
			button.textContent = running ? _('Stop') : _('Start');
			button.classList.toggle('cbi-button-reset', !!running);
			button.classList.toggle('cbi-button-apply', !running);
		}
		else {
			button.inputtitle = running ? _('Stop') : _('Start');
			button.inputstyle = running ? 'reset' : 'apply';
		}
	},

	drawCharts: function(root, dataPoints) {
		if (!root || !window.Chart || !dataPoints || !dataPoints.length)
			return;

		const latencyCanvas = root.querySelector('#passwall-speedtest-latency-chart');

		if (!latencyCanvas)
			return;

		const labels = dataPoints.map(d => d.time);
		const latencyData = dataPoints.map(d => d.latency);

		const tooltip = unitText => ({
			mode: 'index',
			intersect: false,
			callbacks: {
				title: ctx => _('Time') + ': ' + ctx[0].label,
				beforeBody: ctx => {
					const d = dataPoints[ctx[0].dataIndex];
					return 'IP: %s, %s: %s'.format(d.ip, _('Region'), d.region);
				},
				label: ctx => '%s: %s %s'.format(ctx.dataset.label, ctx.parsed.y, unitText)
			}
		});

		const timeScale = {
			type: 'time',
			time: {
				parser: 'yyyy-MM-dd HH:mm:ss',
				tooltipFormat: 'yyyy-MM-dd HH:mm:ss',
				unit: 'hour',
				displayFormats: { hour: 'MM-dd HH:mm' }
			},
			title: { display: true, text: _('Time') },
			offset: true,
			ticks: {
				autoSkip: true,
				maxTicksLimit: 6,
				maxRotation: 45,
				minRotation: 0
			}
		};

		new Chart(latencyCanvas, {
			type: 'line',
			data: {
				labels: labels,
				datasets: [{
					label: _('Latency'),
					data: latencyData,
					borderColor: 'rgba(75, 192, 192, 1)',
					backgroundColor: 'rgba(75, 192, 192, 0.2)',
					tension: 0.3,
					fill: false,
					pointRadius: 4
				}]
			},
			options: {
				responsive: true,
				interaction: tooltip('ms'),
				plugins: {
					tooltip: tooltip('ms'),
					legend: { position: 'top' }
				},
				scales: {
					x: timeScale,
					y: {
						type: 'linear',
						title: { display: true, text: _('Latency') + ' (ms)' }
					}
				}
			}
		});
	},

	render: function(data) {
		let m, s, o;
		let actionButton;
		const status = data[1] || {};
		const bestResult = data[2] || '';
		const history = data[3] || [];
		const nodes = data[4] || {};
		this._wasRunning = !!(status && status.running);
		const passwallNodes = (nodes.passwall && nodes.passwall.nodes) || [];

		m = new form.Map('passwall-speedtest', _('PassWall Speed Test'),
			_('Schedules and runs a PassWall node-based Cloudflare IP latency test, writing the fastest IP back to the selected passwall nodes and other integrations') +
			'<br><a href="https://github.com/urbanescavenger/luci-app-passwall-speedtest" target="_blank">⭐ ' + _('Star on GitHub') + '</a>');

		s = m.section(form.NamedSection, 'global', 'global');
		s.addremove = false;

		s.tab('basic', _('Basic Settings'));

		o = s.taboption('basic', form.Button, '_speedtest', _('Speed test'),
			_('Probes candidate Cloudflare IPs through the selected passwall node(s) via a local SOCKS and measures HTTP HEAD latency (<code>time_pretransfer</code>). Only latency is measured (no download bandwidth). The fastest IP is written back to each passwall worker node.'));
		this.updateButton(o, status.running);
		actionButton = o;
		o.onclick = L.bind(function(ev, sectionId) {
			const button = ev.currentTarget;
			const statusNode = document.getElementById('passwall-speedtest-status');
			const view = this;
			button.disabled = true;

			return callStatus().then(function(st) {
				if (!st.running) {
					// 未运行 → 启动，跳日志页
					return callStart().then(function() {
						window.setTimeout(function() {
							window.location = L.url('admin/services/passwall-speedtest/logread');
						}, 500);
					});
				}
				// 运行中 → 停止：协作式收尾约 ~timeout×probes，轮询到真正退出再把按钮切回 Start
				return callStop().then(function() {
					const waitStopped = function(tries) {
						tries = tries || 0;
						return callStatus().then(function(s) {
							view.updateStatus(statusNode, s);
							if (s && s.running && tries < 30) {
								return new Promise(function(r) { window.setTimeout(r, 2000); })
									.then(function() { return waitStopped(tries + 1); });
							}
							view.updateButton(button, s && s.running);
							return view.refreshResults();
						});
					};
					return waitStopped();
				});
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message));
			}).finally(function() {
				button.disabled = false;
			});
		}, this);

		o = s.taboption('basic', form.ListValue, 'ip_source', _('IP list source'),
			_('Select the built-in Cloudflare IP list, an online CM source, or a custom file used as candidates'));
		o.value('builtin_ipv4', _('Built-in IPv4 list'));
		o.value('builtin_ipv6', _('Built-in IPv6 list'));
		o.value('online', _('Online CM source'));
		o.value('custom_file', _('Custom file'));
		o.default = 'builtin_ipv4';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'ip_online_url', _('Online source URL'),
			_('Source list in <code>IP:PORT#country</code> format. Only :443 entries are kept. Shared by all 5 CM IP lists below.'));
		o.depends('ip_source', 'online');
		o.default = 'https://zip.cm.edu.kg/all.txt';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'custom_ip_file', _('Custom IP list file'),
			_('Enter a local file path, for example: /etc/passwall-speedtest/ip.txt'));
		o.depends('ip_source', 'custom_file');
		o.rmempty = true;
		o.validate = function(sectionId, value) {
			const ipSource = this.section.formvalue(sectionId, 'ip_source');

			if (ipSource == 'custom_file' && !value)
				return _('Custom IP list file is required when using Custom file');

			return true;
		};

		o = s.taboption('basic', form.Flag, 'custom_allip', _('Scan all IPs in each /24'),
			_('Only applies to custom IP lists. Disabled by default: one random IP per /24 is tested. Enable to test every IP in each /24 (slower).'));
		o.depends('ip_source', 'custom_file');
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tl', _('Latency cap (ms)'),
			_('Discard candidate IPs whose average latency is above this threshold (measured via the node\'s local SOCKS).'));
		o.datatype = 'uinteger';
		o.default = '200';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tll', _('Latency lower bound (ms)'),
			_('Discard candidate IPs whose average latency is below this threshold.'));
		o.datatype = 'uinteger';
		o.default = '40';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'tlr', _('Packet loss rate cap'),
			_('Discard candidate IPs whose packet loss ratio exceeds this value (0–1).'));
		o.datatype = 'ufloat';
		o.default = '0.2';
		o.rmempty = false;

		o = s.taboption('basic', form.ListValue, 'node_test_node', _('Passwall node to test through (single-node fallback)'),
			_('Used only when no passwall workers are selected in the Third-Party tab. Select a CF-CDN-fronted passwall node (VLESS/VMess/Trojan/SS…). Its <em>address</em> will be cycled through candidate IPs and finally set to the fastest one. SOCKS-type nodes are not supported.'));
		o.value('', _('-- Please choose --'));
		passwallNodes.forEach(function(n) { o.value(n.value, n.label); });
		o.rmempty = true;

		o = s.taboption('basic', form.ListValue, 'stable_node', _('Passwall stable node (required)'),
			_('During a speed test, passwall\'s global TCP node is temporarily switched to this stable node and restored afterwards, so your live traffic is unaffected by the tested nodes\' <em>address</em> being rewritten. <strong>Required.</strong> Must NOT equal the tested node (single-node fallback) or any selected passwall worker node.'));
		o.value('', _('-- Please choose --'));
		passwallNodes.forEach(function(n) { o.value(n.value, n.label); });
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value || !value.length) return _('Please choose a stable node');
			return true;
		};

		o = s.taboption('basic', form.Value, 'node_test_url', _('Probe URL'),
			_('URL probed via the node\'s local SOCKS; only the HTTP HEAD latency is measured. generate_204 / connectivity-check endpoints are preferred.'));
		o.default = 'https://www.google.com/generate_204';
		o.value('https://www.google.com/generate_204', 'Google');
		o.value('https://www.gstatic.com/generate_204', 'Gstatic');
		o.value('https://speed.cloudflare.com/__down?bytes=1', 'Cloudflare');
		o.value('https://connect.rom.miui.com/generate_204', 'MIUI (CN)');
		o.value('https://connectivitycheck.platform.hicloud.com/generate_204', 'HiCloud (CN)');
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_count', _('Max IPs to test'),
			_('This mode tests IPs through the node (~3-7s each). Cap the count to avoid long runs. With the online CM source the cap is applied <strong>per CM IP list, per worker</strong>, so 5 lists × count × workers × probes can multiply quickly — keep count modest unless you need thoroughness.'));
		o.datatype = 'uinteger';
		o.default = '30';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_timeout', _('Probe timeout (s)'),
			_('Per-IP curl <code>--max-time</code> in seconds.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_probes', _('Probes per IP'),
			_('How many curl probes per candidate IP. Each probe is a full SOCKS+curl, so higher values are slower. If <strong>any</strong> single probe fails, that IP is discarded immediately and the remaining probes are skipped — only IPs that succeed on <em>all</em> probes are kept, so the best IP is a stable one.'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'node_test_threads', _('Max parallel workers'),
			_('Cap on concurrently running passwall workers (only relevant when passwall nodes are selected in the Third-Party tab). 0 means run all workers at once. Each worker runs its own SOCKS+curl chain, so high values need more RAM/CPU — keep ≤ node count and mind router limits.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.rmempty = false;

		s.tab('cron', _('Crontab Settings'));

		o = s.taboption('cron', form.Flag, 'enabled', _('Enabled'),
			_('Enable scheduled task to test the selected IP list'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('cron', form.Flag, 'custom_cron_enabled', _('Enable custom cron'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('cron', form.Value, 'custom_cron', _('Custom Cron'), _('Example: 0 */3 * * *'));
		o.depends('custom_cron_enabled', '1');

		o = s.taboption('cron', form.ListValue, 'hour', _('Interval'));
		o.depends('custom_cron_enabled', '0');
		[1, 2, 3, 4, 6, 8, 12, 24].forEach(function(hour) {
			o.value(hour, _('Every %d hour(s)').format(hour));
		});
		o.default = '24';

		// ── 五个 CM 备选 IP 列表（共享 ip_online_url，仅国家筛选不同）──
		// 始终渲染，通过 data-depends 联动 ip_source 动态显隐（见 m.render().then 中的 cbi_d_add 注册）。
		s = m.section(form.TableSection, 'ip_list', _('CM IP lists (per-country)'),
			_('Define up to 5 CM-source IP lists. All share the online URL above; each filters by its own country set. Assign one list per passwall worker node in the Third-Party tab. Workers without an explicit list use the first enabled list. Only used when IP list source = Online CM source.'));
		s.addremove = false;
		s.anonymous = false;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Name'),
			_('Display label for this list, shown in the per-node dropdown.'));
		o.rmempty = true;

		o = s.option(form.MultiValue, 'regions', _('Country filter'),
			_('Only keep :443 IPs tagged with the selected countries. Leave none selected to keep all :443 IPs.'));
		o.value('JP', _('Japan'));
		o.value('SG', _('Singapore'));
		o.value('KR', _('South Korea'));
		o.value('HK', _('Hong Kong'));
		o.value('TW', _('Taiwan'));
		o.value('TH', _('Thailand'));
		o.value('VN', _('Vietnam'));
		o.value('ID', _('Indonesia'));
		o.value('PH', _('Philippines'));
		o.value('MY', _('Malaysia'));
		o.value('IN', _('India'));
		o.value('KH', _('Cambodia'));
		o.value('DE', _('Germany'));
		o.value('NL', _('Netherlands'));
		o.value('FR', _('France'));
		o.value('GB', _('United Kingdom'));
		o.value('FI', _('Finland'));
		o.value('SE', _('Sweden'));
		o.value('CH', _('Switzerland'));
		o.value('RU', _('Russia'));
		o.value('TR', _('Turkey'));
		o.value('UA', _('Ukraine'));
		o.value('US', _('United States'));
		o.value('CA', _('Canada'));
		o.value('BR', _('Brazil'));
		o.value('AU', _('Australia'));
		o.value('AE', _('United Arab Emirates'));
		o.value('ZA', _('South Africa'));

		s = m.section(form.NamedSection, 'global', 'global', _('Best IP'));
		s.addremove = false;
		o = s.option(form.TextValue, '_best_result');
		o.rows = 8;
		o.readonly = true;
		o.wrap = 'off';
		o.cfgvalue = function() {
			return typeof bestResult == 'string' ? bestResult : (bestResult.content || '');
		};
		o.write = function() {};

		return m.render().then(L.bind(function(formNode) {
			const statusNode = E('p', { id: 'passwall-speedtest-status' }, _('Collecting data...'));
			this.updateStatus(statusNode, status);
			// 真实 DOM 按钮（option 对象改 inputtitle 不会更新已渲染 DOM，轮询必须拿 DOM 元素）
			const domButton = formNode.querySelector('[name="cbid.passwall-speedtest.global._speedtest"]');

			const chartNode = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('History Charts')),
				chartCss(),
				E('div', { 'class': 'passwall-speedtest-chart-container' }, [
					E('canvas', { id: 'passwall-speedtest-latency-chart' })
				])
			]);

			const root = E([], [
				E('div', { 'class': 'cbi-section' }, [ statusNode ]),
				formNode
			]);

			const formActions = formNode.querySelector('.cbi-page-actions');

			if (formActions && formActions.parentNode)
				formActions.parentNode.insertBefore(chartNode, formActions);
			else
				formNode.appendChild(chartNode);

			// CM IP lists 表格格式：单元格居中、控件字体匹配表格紧凑尺寸
			formNode.insertBefore(tableCss(), formNode.firstChild);

			// 联动显隐：ip_source != online 时隐藏「CM IP lists」TableSection
			// 通过 LuCI CBI 的 data-depends 机制实现，无需页面刷新。
			// cbi_init() 在 DOMContentLoaded 时已执行，所以这里手动调用 cbi_d_add。
			// 注意：不能在这里调 cbi_d_update()——此时 formNode 尚未挂载到 document，
			// document.getElementById() 找不到 detached 元素，cbi_tag_last 会因
			// parent=null 而抛 TypeError。改为手动设置初始显隐；后续用户切换
			// ip_source 时 cbi_d_update() 正常触发，依赖系统接管。
			var ipListContainer = null;
			formNode.querySelectorAll('h2, h3, h4, h5, legend, .cbi-section-title').forEach(function(h) {
				if (/CM IP lists/.test(h.textContent)) {
					ipListContainer = h.closest('.cbi-section') || h.closest('fieldset') || h.closest('div');
				}
			});
			if (ipListContainer) {
				// cbi_d_update 通过 document.getElementById(entry.id) 查找元素，
				// 确保容器有 id（LuCI 通常已设置，此处兜底）。
				if (!ipListContainer.id)
					ipListContainer.id = 'cbi-passwall-speedtest-ip_list';
				var ipListIdx = Array.prototype.indexOf.call(ipListContainer.parentNode.children, ipListContainer);
				ipListContainer.setAttribute('data-depends',
					JSON.stringify([{'cbid.passwall-speedtest.global.ip_source': 'online'}]));
				ipListContainer.setAttribute('data-index', String(ipListIdx));
				if (typeof cbi_d_add === 'function') {
					cbi_d_add(ipListContainer,
						{ 'cbid.passwall-speedtest.global.ip_source': 'online' }, ipListIdx);
				}
				// 初始显隐：formNode 尚未挂载，手动设置；后续由 cbi_d_update 接管
				if (uci.get('passwall-speedtest', 'global', 'ip_source') !== 'online')
					ipListContainer.style.display = 'none';
			}

			poll.add(L.bind(this.pollStatus, this, statusNode, domButton), 3);

			script(L.resource('passwall-speedtest/chart.js')).then(function() {
				return script(L.resource('passwall-speedtest/chartjs-adapter-date-fns.js'));
			}).then(L.bind(function() {
				this.drawCharts(chartNode, history);
			}, this));

			return root;
		}, this));
	}
});