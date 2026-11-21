const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function harness(files = new Map()) {
  const state = { time: 10000, counters: { uploadedBytes: 100, downloadedBytes: 200 }, failWrite: false,
    shortWrite: false, failRead: false, nativeError: false, heartbeat: undefined, logs: [], connectionPhases: [] };
  const context = { getApplicationContext: () => ({ filesDir: '/virtual' }) };
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_WRITE: 8, APPEND: 16 },
    accessSync: filename => files.has(filename),
    mkdirSync: () => {},
    openSync: (filename, mode) => {
      if (mode & 4 || !files.has(filename)) files.set(filename, '');
      return { fd: filename };
    },
    writeSync: (fd, data) => {
      const text = typeof data === 'string' ? data : Buffer.from(data).toString('utf8');
      files.set(fd, text);
      return Buffer.byteLength(text) - (state.shortWrite && fd.includes('server-traffic') ? 1 : 0);
    },
    closeSync: () => {},
    fsyncSync: () => {},
    renameSync: (from, to) => {
      if (state.failWrite && to.includes('server-traffic')) throw new Error('disk failure');
      files.set(to, files.get(from));
      files.delete(from);
      if (to === '/virtual/connection-state.json') {
        state.connectionPhases.push(JSON.parse(files.get(to)).phase);
      }
    },
    readTextSync: filename => {
      if (state.failRead && filename.includes('server-traffic')) throw new Error('read failure');
      if (!files.has(filename)) throw new Error('missing file');
      return files.get(filename);
    }
  };
  const native = {
    getTrafficStats: () => {
      if (state.nativeError) throw new Error('native statistics unavailable');
      return { ...state.counters };
    },
    clearCloexec: () => {},
    startTun2Socks: () => true
  };
  const imports = {
    '@kit.AbilityKit': {},
    '@kit.CoreFileKit': { fileIo },
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'session-1', TextEncoder: class {
      encodeInto(text) { return new TextEncoder().encode(text); }
    } } },
    '@kit.PerformanceAnalysisKit': { hilog: {
      info: (...args) => state.logs.push(args), error: (...args) => state.logs.push(args)
    } },
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => state.time } },
    '@kit.NetworkKit': { VpnExtensionAbility: class { context = context; } },
    '../model/NativeBridge': { getNative: () => native },
    '../model/SsConfig': {},
    '../model/RoutingStore': {}
  };
  const cache = new Map();
  function load(relative) {
    if (cache.has(relative)) return cache.get(relative);
    const filename = path.join(__dirname, '../main/ets', relative + '.ets');
    const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    const exports = {};
    vm.runInNewContext(source, {
      exports, require: name => name in imports ? imports[name] : load(path.posix.normalize(path.posix.join(path.posix.dirname(relative), name))),
      Date: class extends Date { static now() { return state.time; } },
      setInterval: callback => { state.heartbeat = callback; return 1; },
      clearInterval: () => { state.heartbeat = undefined; }
    }, { filename });
    cache.set(relative, exports);
    return exports;
  }
  return { ...load('model/TrafficStore'), ...load('model/AppLog'), files, state, context,
    Vpn: load('vpnability/VpnExtAbility').default };
}

test('rates use elapsed sample time; totals survive idle periods and a fresh session baseline', () => {
  const { TrafficSession, formatTraffic } = harness();
  const session = new TrafficSession({ uploadedBytes: 1024, downloadedBytes: 2048 },
    { uploadedBytes: 500, downloadedBytes: 700 }, 1000);
  const sample = session.sample({ uploadedBytes: 2548, downloadedBytes: 1724 }, 3000);
  assert.equal(sample.uploadSpeed, 1024);
  assert.equal(sample.downloadSpeed, 512);
  assert.equal(sample.uploadedBytes, 3072);
  assert.equal(sample.downloadedBytes, 3072);
  const idle = session.sample({ uploadedBytes: 2548, downloadedBytes: 1724 }, 4000);
  assert.equal(idle.uploadSpeed, 0);
  assert.equal(idle.downloadSpeed, 0);
  const resumed = new TrafficSession(idle, { uploadedBytes: 80, downloadedBytes: 90 }, 10000);
  const next = resumed.sample({ uploadedBytes: 180, downloadedBytes: 290 }, 11000);
  assert.equal(next.uploadedBytes, 3172);
  assert.equal(next.downloadedBytes, 3272);
  assert.equal(formatTraffic(next.uploadedBytes), '3.1 KiB');
  assert.equal(formatTraffic(0), '0 B');
  assert.equal(formatTraffic(1024 ** 3), '1.0 GiB');
  assert.throws(() => resumed.sample({ uploadedBytes: 0, downloadedBytes: 0 }, 12000));
  assert.throws(() => resumed.sample({ uploadedBytes: NaN, downloadedBytes: 290 }, 12000));
  assert.throws(() => resumed.sample({ uploadedBytes: 180, downloadedBytes: 290 }, 10000));
});

test('atomic persistence survives reopening, failed writes and non-ASCII IDs', () => {
  const h = harness();
  const entries = [{ serverId: '节点', uploadedBytes: 123, downloadedBytes: 456 }];
  h.TrafficStore.save(h.context, entries);
  const reopened = harness(h.files);
  assert.deepEqual(JSON.parse(JSON.stringify(reopened.TrafficStore.load(reopened.context))), entries);
  for (const flag of ['failWrite', 'shortWrite']) {
    h.state[flag] = true;
    assert.throws(() => h.TrafficStore.save(h.context, [{ ...entries[0], uploadedBytes: 999 }]));
    assert.equal(h.TrafficStore.load(h.context)[0].uploadedBytes, 123);
    h.state[flag] = false;
  }
  h.files.set('/virtual/server-traffic.json', '[{"serverId":"bad","uploadedBytes":-1,"downloadedBytes":0}]');
  assert.throws(() => h.TrafficStore.load(h.context));
});

async function connect(h, serverId) {
  const vpn = new h.Vpn();
  vpn.startPipeline = async () => {
    await vpn.startTun2socks();
    vpn.phase = 'connected';
    vpn.sampleTraffic();
    vpn.publishState();
  };
  vpn.onCreate({ parameters: { serverId } });
  await new Promise(resolve => setImmediate(resolve));
  return vpn;
}

test('VPN heartbeat persists per-server totals without UI, retries writes and flushes disconnect', async () => {
  const h = harness();
  const vpn = await connect(h, 'A');
  h.state.time += 2000;
  h.state.counters = { uploadedBytes: 1100, downloadedBytes: 2200 };
  h.state.heartbeat();
  let connection = h.readConnectionState(h.context);
  assert.equal(connection.serverId, 'A');
  assert.equal(connection.traffic.uploadSpeed, 500);
  assert.equal(connection.traffic.downloadSpeed, 1000);
  assert.equal(h.TrafficStore.load(h.context)[0].uploadedBytes, 1000);

  h.state.failWrite = true;
  h.state.time += 1000;
  h.state.counters.uploadedBytes += 100;
  h.state.heartbeat();
  connection = h.readConnectionState(h.context);
  assert.ok(connection.trafficError);
  assert.equal(connection.traffic, undefined);
  assert.equal(h.TrafficStore.load(h.context)[0].uploadedBytes, 1000);
  h.state.failWrite = false;
  h.state.time += 1000;
  h.state.heartbeat();
  assert.equal(h.TrafficStore.load(h.context)[0].uploadedBytes, 1100);
  assert.equal(h.readConnectionState(h.context).trafficError, '');
  assert.equal(h.readConnectionState(h.context).traffic.uploadSpeed, 0);

  h.state.counters.downloadedBytes += 150;
  h.requestVpnStop(h.context, h.readConnectionState(h.context).sessionId, 'stop-1');
  const beforeStop = h.state.connectionPhases.length;
  h.state.heartbeat();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(h.state.connectionPhases.slice(beforeStop), ['disconnecting', 'disconnected']);
  const stopped = h.readConnectionState(h.context);
  assert.equal(stopped.phase, 'disconnected');
  assert.equal(stopped.stopRequestId, 'stop-1');
  vpn.onDestroy();
  assert.equal(h.state.heartbeat, undefined);
  assert.equal(h.readConnectionState(h.context).traffic, undefined);
  assert.equal(h.TrafficStore.load(h.context)[0].downloadedBytes, 2150);

  const next = harness(h.files);
  const other = await connect(next, 'B');
  next.state.time += 1000;
  next.state.counters.uploadedBytes += 300;
  next.state.heartbeat();
  other.onDestroy();
  const again = await connect(next, 'A');
  next.state.time += 1000;
  next.state.counters.uploadedBytes += 40;
  next.state.heartbeat();
  const entries = next.TrafficStore.load(next.context);
  assert.equal(entries.find(entry => entry.serverId === 'A').uploadedBytes, 1140);
  assert.equal(entries.find(entry => entry.serverId === 'B').uploadedBytes, 300);
  next.state.time += 5001;
  assert.equal(next.readConnectionState(next.context).phase, 'disconnected');
  assert.equal(next.readConnectionState(next.context).traffic, undefined);
  again.onDestroy();
});

test('unavailable native counters or corrupt history report errors without overwriting saved usage', async () => {
  for (const nativeError of [false, true]) {
    const h = harness();
    const saved = nativeError ? '[{"serverId":"A","uploadedBytes":9,"downloadedBytes":8}]' : 'corrupt';
    h.files.set('/virtual/server-traffic.json', saved);
    h.state.nativeError = nativeError;
    const vpn = await connect(h, 'A');
    h.state.time += 1000;
    h.state.heartbeat();
    assert.equal(h.readConnectionState(h.context).phase, 'connected');
    assert.ok(h.readConnectionState(h.context).trafficError);
    assert.equal(h.files.get('/virtual/server-traffic.json'), saved);
    vpn.onDestroy();
  }
});
