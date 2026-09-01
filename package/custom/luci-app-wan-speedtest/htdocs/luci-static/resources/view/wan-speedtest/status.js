'use strict';
'require view';
'require fs';
'require network';
'require poll';
'require ui';

function runHelper(action, iface) {
	var args = [ action ];
	if (iface)
		args.push(iface);
	return fs.exec('/usr/libexec/wan-speedtest', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function numberValue(result, names) {
	for (var i = 0; i < names.length; i++) {
		var value = result && result[names[i]];
		if (value !== null && value !== undefined && value !== '')
			return value;
	}
	return '—';
}

function normalizeResult(result) {
	if (Array.isArray(result))
		return result.length ? result[0] : null;
	return result || null;
}

function metricValue(result, names, unit) {
	var value = numberValue(result, names);
	if (value === '—')
		return value;
	var numeric = Number(value);
	return (Number.isFinite(numeric) ? numeric.toFixed(2) : String(value)) + ' ' + unit;
}

return view.extend({
	load: function() {
		return Promise.all([
			network.getNetworks(),
			L.resolveDefault(runHelper('status'), { state: 'idle', result: null })
		]);
	},

	render: function(data) {
		var networks = data[0] || [];
		var initial = data[1] || {};
		var select = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: '' }, _('Automatic route selection'))
		]);

		networks.forEach(function(net) {
			var dev = net.getL3Device();
			if (!dev)
				return;
			var name = dev.getName();
			select.appendChild(E('option', { value: name }, '%s (%s)'.format(net.getName(), name)));
		});

		var state = E('span', { 'class': 'label' }, [ _('Idle') ]);
		var result = E('div', { 'class': 'cbi-section' });
		var start = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ _('Start test') ]);
		var stop = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'disabled': 'disabled' }, [ _('Stop') ]);

		function renderStatus(info) {
			info = info || {};
			var running = info.state === 'running';
			state.textContent = ({
				idle: _('Idle'), running: _('Testing…'), complete: _('Complete'),
				failed: _('Failed'), cancelled: _('Cancelled')
			})[info.state] || info.state || _('Idle');
			start.disabled = running;
			stop.disabled = !running;

			var r = normalizeResult(info.result);
			if (!r) {
				result.replaceChildren(E('p', {}, [ running ? _('The test is running in the background.') : _('No result yet.') ]));
				return;
			}
			var server = r.server && (r.server.name || r.server.location || r.server.url || r.server.id);
			result.replaceChildren(E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Download') ]), E('div', { 'class': 'td' }, [ metricValue(r, [ 'download', 'download_speed' ], 'Mbps') ]) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Upload') ]), E('div', { 'class': 'td' }, [ metricValue(r, [ 'upload', 'upload_speed' ], 'Mbps') ]) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Ping') ]), E('div', { 'class': 'td' }, [ metricValue(r, [ 'ping', 'latency' ], 'ms') ]) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Jitter') ]), E('div', { 'class': 'td' }, [ metricValue(r, [ 'jitter' ], 'ms') ]) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Server') ]), E('div', { 'class': 'td' }, [ String(server || '—') ]) ])
			]));
		}

		start.addEventListener('click', function() {
			start.disabled = true;
			runHelper('start', select.value).then(renderStatus).catch(function(err) {
				ui.addNotification(null, E('p', {}, [ _('Unable to start test: %s').format(err.message) ]));
			});
		});
		stop.addEventListener('click', function() {
			runHelper('stop').then(renderStatus);
		});

		poll.add(function() {
			return L.resolveDefault(runHelper('status'), {}).then(renderStatus);
		}, 2);
		renderStatus(initial);

		return E([], [
			E('h2', {}, [ _('WAN Speed Test') ]),
			E('div', { 'class': 'cbi-map-descr' }, [ _('LibreSpeed runs locally on the router. Telemetry is disabled and HTTPS-capable servers are required.') ]),
			E('div', { 'class': 'cbi-section' }, [
				E('label', { 'style': 'margin-right:1em' }, [ _('Egress interface') ]), select,
				E('span', { 'style': 'margin-left:1em' }, [ start, ' ', stop ]),
				E('p', {}, [ _('Status: '), state ])
			]),
			result
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
