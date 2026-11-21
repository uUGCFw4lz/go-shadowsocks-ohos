const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function harness(connection) {
  const events = [];
  const states = [];
  const acknowledgments = [];
  let heartbeat;
  let stopRequest = '';
  const imports = {
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'session-1' } },
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, vpnExtension: {
      createVpnConnection: () => ({ generateVpnId: async () => 'owned-vpn', ...connection })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
    '../model/AppLog': {
      appendLog: (_context, message) => events.push(message),
      readVpnStopRequest: () => stopRequest,
      writeConnectionState: (_context, phase, _server, _traffic, _trafficError, _error, sessionId, requestId) => {
        states.push(phase);
        acknowledgments.push({ phase, sessionId, requestId });
      }
    },
    '../model/RoutingStore': { isRouteMode: mode => ['global', 'gfwlist', 'bypass-lan-china'].includes(mode) },
    '../model/TrafficStore': {},
    '../model/SsConfig': {}
  };
  const filename = path.join(__dirname, '../main/ets/vpnability/VpnExtAbility.ets');
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, {
    exports, require: name => {
      assert.ok(name in imports, name);
      return imports[name];
    }, setInterval: fn => { heartbeat = fn; return 1; }, clearInterval() {}
  }, { filename });
  const ability = new exports.default();
  ability.context = {};
  ability.startSsEngine = async () => events.push('engine');
  ability.startTun2socks = async () => events.push('tun');
  ability.sampleTraffic = () => {};
  return { ability, events, states, acknowledgments, requestStop: id => { stopRequest = id; heartbeat(); } };
}

test('VPN is created and destroyed using the generated ID', async () => {
  const calls = [];
  const { ability } = harness({
    protectProcessNet: async () => { calls.push('protect'); },
    create: async config => { calls.push(['create', config.vpnId]); return 17; },
    destroy: async id => { calls.push(['destroy', id]); }
  });
  await ability.startPipeline();
  assert.equal(ability.phase, 'connected');
  await ability.stopPipeline();
  assert.deepEqual(calls, ['protect', ['create', 'owned-vpn'], ['destroy', 'owned-vpn']]);
});

test('create failures do not retry or destroy another VPN', async () => {
  for (const code of [2200003, 2203002]) {
    let creates = 0;
    const destroys = [];
    const { ability, states } = harness({
      protectProcessNet: async () => {},
      create: async () => { creates++; throw { code }; },
      destroy: async id => { destroys.push(id); }
    });
    ability.onCreate({ parameters: { routeMode: 'gfwlist' } });
    await ability.starting;
    assert.equal(creates, 1);
    assert.deepEqual(destroys, ['owned-vpn']);
    assert.equal(states.at(-1), 'failed');
    assert.ok(ability.connectionError.includes(String(code)));
  }
});

test('cancelling during protection prevents engine and TUN startup', async () => {
  const protection = deferred();
  let creates = 0;
  let destroys = 0;
  const { ability, events, states } = harness({
    protectProcessNet: () => protection.promise,
    create: async () => { creates++; return 17; },
    destroy: async () => { destroys++; }
  });
  ability.onCreate({ parameters: { routeMode: 'bypass-lan-china' } });
  ability.onDestroy();
  assert.equal(states.at(-1), 'disconnecting');
  protection.resolve();
  await ability.finishStop();
  assert.equal(creates, 0);
  assert.equal(destroys, 0);
  assert.ok(!events.includes('engine') && !events.includes('tun'));
  assert.equal(states.at(-1), 'disconnected');
});

test('cancelling pending VPN creation waits for create before destroying it', async () => {
  const creation = deferred();
  const destruction = deferred();
  const calls = [];
  const { ability, states, events, acknowledgments, requestStop } = harness({
    protectProcessNet: async () => {},
    create: async () => { calls.push('create'); return creation.promise; },
    destroy: async () => { calls.push('destroy'); await destruction.promise; }
  });
  ability.onCreate({ parameters: { routeMode: 'gfwlist' } });
  await new Promise(resolve => setImmediate(resolve));
  requestStop('stop-1');
  assert.deepEqual(calls, ['create']);
  creation.resolve(17);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls, ['create', 'destroy']);
  assert.equal(states.at(-1), 'disconnecting');
  destruction.resolve();
  await ability.finishStop();
  assert.equal(states.at(-1), 'disconnected');
  assert.deepEqual(acknowledgments.at(-1), { phase: 'disconnected', sessionId: 'session-1', requestId: 'stop-1' });
  ability.onDestroy();
  assert.deepEqual(calls, ['create', 'destroy']);
  assert.equal(states.at(-1), 'disconnected');
  assert.ok(!events.includes('tun'));
});

test('an explicit stop failure can be retried while the extension is alive', async () => {
  let destroys = 0;
  const { ability, acknowledgments, requestStop } = harness({
    protectProcessNet: async () => {},
    create: async () => 17,
    destroy: async () => { if (++destroys === 1) throw new Error('system refused'); }
  });
  ability.onCreate({ parameters: { routeMode: 'gfwlist' } });
  await ability.starting;
  requestStop('first');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(acknowledgments.at(-1), { phase: 'stop-failed', sessionId: 'session-1', requestId: 'first' });
  requestStop('first');
  assert.equal(destroys, 1);
  requestStop('second');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(acknowledgments.at(-1), { phase: 'disconnected', sessionId: 'session-1', requestId: 'second' });
  assert.equal(destroys, 2);
});
