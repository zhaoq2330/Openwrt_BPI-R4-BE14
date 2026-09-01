'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const sourcePath = path.join(__dirname, '..', 'htdocs', 'luci-static', 'resources', 'view', 'wan-speedtest', 'status.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const marker = 'return view.extend';
const markerIndex = source.indexOf(marker);
assert(markerIndex > 0, 'LuCI view marker is missing');

const context = {};
vm.runInNewContext(
	source.slice(0, markerIndex) +
	'\nthis.testExports = { normalizeResult: normalizeResult, metricValue: metricValue };',
	context
);

const normalizeResult = context.testExports.normalizeResult;
const metricValue = context.testExports.metricValue;
const fixture = {
	download: 912.345,
	upload: 123.4,
	ping: 8.9,
	jitter: 1.2,
	server: { name: 'fixture' }
};

assert.strictEqual(normalizeResult([fixture]).server.name, 'fixture');
assert.strictEqual(normalizeResult(fixture).server.name, 'fixture');
assert.strictEqual(normalizeResult([]), null);
assert.strictEqual(metricValue(fixture, [ 'download' ], 'Mbps'), '912.35 Mbps');
assert.strictEqual(metricValue(fixture, [ 'ping' ], 'ms'), '8.90 ms');
assert.strictEqual(metricValue({}, [ 'download' ], 'Mbps'), '—');

console.log('WAN speed-test result-shape tests passed');
