'use strict';
'require dom';
'require poll';
'require rpc';
'require ui';
'require view';

var callStatus = rpc.declare({ object: 'agent-runtime', method: 'status' });
var callList = rpc.declare({ object: 'agent-runtime', method: 'list' });
var callJobStatus = rpc.declare({ object: 'agent-runtime', method: 'job_status', params: [ 'job_id' ] });
var callOperationLog = rpc.declare({ object: 'agent-runtime', method: 'operation_log', params: [ 'operation_id' ] });
var actions = {};

[ 'check', 'upgrade', 'rollback', 'verify', 'gc' ].forEach(function(action) {
	actions[action] = rpc.declare({ object: 'agent-runtime', method: action });
});

function parseOutput(reply) {
	if (!reply || !reply.output)
		return null;

	try {
		return JSON.parse(reply.output);
	}
	catch (e) {
		return null;
	}
}

function text(value) {
	if (value === null || value === undefined || value === '')
		return '—';
	if (typeof value === 'object')
		return JSON.stringify(value);
	return String(value);
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), callList() ]);
	},

	render: function(data) {
		var self = this;
		var statusBox = E('div', { 'class': 'cbi-section' }, E('em', {}, _('Loading…')));
		var generationBox = E('div', { 'class': 'cbi-section' });
		var jobBox = E('pre', {
			'class': 'agent-runtime-log',
			'style': 'max-height:20rem; overflow:auto; white-space:pre-wrap; word-break:break-word;'
		}, _('No operation is running.'));
		var currentJob = null;
		var currentOperation = null;

		function showStatus(reply, listReply) {
			var parsed = parseOutput(reply) || {};
			var payload = parsed.data || {};
			var rows = [
				[ _('Baked baseline'), text(payload.baseline_release || payload.baseline) ],
				[ _('Active generation'), text(payload.active_release || payload.active) ],
				[ _('Previous generation'), text(payload.previous) ],
				[ _('Latest signed release'), text(payload.latest_release || payload.latest) ],
				[ _('Data ready'), payload.data_ready === undefined ? '—' : (payload.data_ready ? _('Yes') : _('No')) ],
				[ _('Health'), text(payload.health) ],
				[ _('Free space (KiB)'), text(payload.free_space_kb) ],
				[ _('Node ABI'), text(payload.node_abi) ],
				[ _('uv / CPython'), text(payload.contract && payload.contract.uv_version) + ' / ' + text(payload.contract && payload.contract.cpython_series) ],
				[ _('Manager result'), text(parsed.message || reply.message) ]
			];

			dom.content(statusBox, E('table', { 'class': 'table cbi-section-table' }, rows.map(function(row) {
				return E('tr', {}, [ E('th', {}, row[0]), E('td', {}, row[1]) ]);
			})));

			var listed = parseOutput(listReply) || {};
			var generations = (listed.data && listed.data.generations) || payload.generations || [];
			dom.content(generationBox, [
				E('h3', {}, _('Installed generations')),
				E('pre', { 'style': 'white-space:pre-wrap; word-break:break-word;' }, JSON.stringify(generations, null, 2)),
				E('h3', {}, _('Components and runtime contract')),
				E('pre', { 'style': 'white-space:pre-wrap; word-break:break-word;' },
					JSON.stringify({
						components: payload.components || {},
						contract: payload.contract || {
							architecture: payload.architecture || payload.arch,
							libc: payload.libc,
							node_abi: payload.node_abi,
							uv: payload.uv_version,
							cpython: payload.python_version || payload.cpython_version
						}
					}, null, 2))
			]);
		}

		function refresh() {
			return Promise.all([ callStatus(), callList() ]).then(function(replies) {
				showStatus(replies[0], replies[1]);
			}).catch(function(err) {
				dom.content(statusBox, E('em', { 'class': 'alert-message warning' }, String(err)));
			});
		}

		function showJob(reply) {
			if (!reply || !reply.data) {
				dom.content(jobBox, _('Unable to read job status.'));
				return;
			}

			var job = reply.data;
			var output = job.output || '';
			var parsed = parseOutput({ output: output });
			if (parsed && parsed.operation_id)
				currentOperation = parsed.operation_id;

			dom.content(jobBox, [
				_('Job: %s\nState: %s\nExit code: %s\n\n').format(job.job_id, job.state, text(job.exit_code)),
				output || _('Waiting for command output…')
			]);

			if (job.state === 'completed')
				refresh();
		}

		function queue(action) {
			return actions[action]().then(function(reply) {
				if (!reply || !reply.ok) {
					ui.addNotification(null, E('p', {}, reply ? reply.message : _('Operation was rejected.')), 'danger');
					return;
				}

				currentJob = reply.job_id;
				currentOperation = null;
				dom.content(jobBox, _('Queued %s (job %s)…').format(action, currentJob));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'danger');
			});
		}

		var buttons = [
			[ 'check', _('Check for signed release'), 'cbi-button-neutral' ],
			[ 'upgrade', _('Upgrade full stack'), 'cbi-button-action important' ],
			[ 'verify', _('Verify active generation'), 'cbi-button-neutral' ],
			[ 'rollback', _('Rollback'), 'cbi-button-negative' ],
			[ 'gc', _('Clean old generations'), 'cbi-button-neutral' ]
		].map(function(item) {
			return E('button', {
				'class': 'cbi-button ' + item[2],
				'click': ui.createHandlerFn(self, function() { return queue(item[0]); })
			}, item[1]);
		});

		poll.add(function() {
			var requests = [ refresh() ];
			if (currentJob)
				requests.push(callJobStatus(currentJob).then(showJob));
			if (currentOperation)
				requests.push(callOperationLog(currentOperation).then(function(reply) {
					if (reply && reply.ok && reply.data && reply.data.output)
						dom.content(jobBox, reply.data.output);
				}));
			return Promise.all(requests);
		}, 5);

		showStatus(data[0], data[1]);
		return E([], [
			E('h2', {}, _('Agent Runtime')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Manage only signed, whole-stack runtime generations. Node, uv, CPython and OpenWrt itself remain firmware-managed.')),
			statusBox,
			E('div', { 'class': 'cbi-section' }, buttons),
			generationBox,
			E('h3', {}, _('Operation log (last 16 KiB)')),
			jobBox,
			E('p', { 'class': 'cbi-section-descr' }, [
				_('OpenClaw is managed separately. '),
				E('a', { 'href': L.url('admin/services/openclaw') }, _('Open OpenClaw management'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
