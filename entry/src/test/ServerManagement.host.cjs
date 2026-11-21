const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../main/ets/pages/Index.ets'), 'utf8');
const start = source.indexOf('  private context():');
const end = source.indexOf('  @Builder', start);
assert.ok(start >= 0 && end > start);
const code = ts.transpileModule(`class Probe { ${source.slice(start, end)} }; globalThis.Probe = Probe;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;

function harness(requested = true, vpnOverrides = {}) {
  const active = { id: 'active', name: 'Active', host: 'example.com', port: 8388, method: 'aes-256-gcm', password: 'fixture' };
  const other = { ...active, id: 'other', name: 'Other' };
  const imported = { ...other, id: '', name: 'Imported' };
  const saves = [];
  const dialogs = [];
  let clipboardReads = 0;
  let scans = 0;
  const scanState = { error: undefined, supported: true, invalidLink: false };
  let failSave = false;
  let connectionState = { phase: 'connected', serverId: 'active', updatedAt: 1234 };
  const trafficEntries = [
    { serverId: 'active', uploadedBytes: 100, downloadedBytes: 200 },
    { serverId: 'other', uploadedBytes: 300, downloadedBytes: 400 }
  ];
  const sandbox = {
    Date: class extends Date { static now() { return 1234; } },
    CIPHERS: ['aes-256-gcm'],
    LIGHT_THEME: { danger: '#FF0000' },
    validateServer: () => '',
    parseServerUrl: () => {
      if (scanState.invalidLink) throw new Error('服务器链接无效');
      return { ...imported };
    },
    ServerStore: { save: async (_context, settings) => {
      if (failSave) throw new Error('write failure');
      saves.push(JSON.parse(JSON.stringify(settings)));
    } },
    RoutingStore: { saveMode: () => { throw new Error('must not switch active routing'); } },
    pasteboard: { getSystemPasteboard: () => ({ getData: async () => {
      clipboardReads++;
      return { getPrimaryText: () => 'ss://fixture' };
    } }) },
    scanCore: { ScanType: { QR_CODE: 11 }, ScanErrorCode: { SCAN_SERVICE_CANCELED: 1000500002 },
      isDefaultScanSupported: () => scanState.supported },
    scanBarcode: { startScanForResult: async () => {
      scans++;
      if (scanState.error) throw scanState.error;
      return { originalValue: 'ss://fixture' };
    } },
    readConnectionState: () => connectionState,
    TrafficStore: { load: () => trafficEntries },
    formatTraffic: bytes => `${bytes} B`,
    ...vpnOverrides
  };
  vm.runInNewContext(code, sandbox);
  const page = new sandbox.Probe();
  Object.assign(page, {
    servers: [active, other], selectedId: active.id, ready: true, busy: false, saving: false,
    requested, connected: requested, editing: false, editId: '', importing: false, importingBusy: false,
    updatingRules: false, routeMode: 'global', requestTime: 0, trafficEntries: [], trafficError: '',
    getUIContext: () => ({ getHostContext: () => ({}), showAlertDialog: options => dialogs.push(options) })
  });
  return { page, active, other, saves, dialogs, scanState, counts: () => ({ clipboardReads, scans }), fail: () => { failSave = true; },
    setConnection: value => { connectionState = value; } };
}

test('stop waits for matching cleanup acknowledgment before stopping the extension', async () => {
  let scheduled;
  const actions = [];
  const { page, setConnection } = harness(true, {
    util: { generateRandomUUID: () => 'stop-1' },
    requestVpnStop: (_context, session, request) => { actions.push(['request', session, request]); },
    vpnExtension: { stopVpnExtensionAbility: async () => { actions.push('stop extension'); } },
    setTimeout: resolve => { scheduled = resolve; }
  });
  const session = { sessionId: 'vpn-1', updatedAt: 1234 };
  setConnection({ ...session, phase: 'connected' });
  const stopping = page.stopVpn({});
  assert.deepEqual(actions, [['request', 'vpn-1', 'stop-1']]);
  setConnection({ ...session, phase: 'disconnected', stopRequestId: 'old-request' });
  scheduled();
  await Promise.resolve();
  assert.equal(actions.length, 1);
  setConnection({ ...session, sessionId: 'vpn-2', phase: 'disconnected', stopRequestId: 'stop-1' });
  scheduled();
  await Promise.resolve();
  assert.equal(actions.length, 1);
  setConnection({ ...session, phase: 'disconnected', stopRequestId: 'stop-1' });
  scheduled();
  await stopping;
  assert.deepEqual(actions, [['request', 'vpn-1', 'stop-1'], 'stop extension']);
});

test('stop reports cleanup failure without stopping the extension', async () => {
  let stopped = false;
  const { page, setConnection } = harness(true, {
    util: { generateRandomUUID: () => 'stop-1' },
    requestVpnStop: (_context, sessionId, stopRequestId) => {
      setConnection({ sessionId, stopRequestId, phase: 'stop-failed', connectionError: 'VPN 断开失败' });
    },
    vpnExtension: { stopVpnExtensionAbility: async () => { stopped = true; } }
  });
  setConnection({ sessionId: 'vpn-1', phase: 'connected' });
  await assert.rejects(page.stopVpn({}), /VPN 断开失败/);
  assert.equal(stopped, false);
});

test('connected manual add and active-server copy preserve active configuration and selection', async () => {
  const { page, active, saves } = harness();
  const original = JSON.stringify(active);
  page.openEditor();
  assert.equal(page.editing, true);
  assert.equal(page.editId, '');
  Object.assign(page, { editName: 'Manual', editHost: 'new.example.com', editPort: '443', editPassword: 'new' });
  await page.saveServer();
  page.duplicateServer(active);
  assert.equal(page.editId, '');
  assert.equal(page.editName, 'Active 副本');
  assert.equal(page.editPassword, active.password);
  await page.saveServer();
  assert.equal(page.servers.length, 4);
  assert.equal(new Set(page.servers.map(server => server.id)).size, 4);
  assert.equal(JSON.stringify(active), original);
  assert.equal(page.selectedId, active.id);
  assert.ok(saves.every(saved => saved.selectedId === active.id));
  assert.equal(page.requested, true);
  assert.equal(page.connected, true);
});

test('URL, clipboard and scanner imports remain available while connected', async () => {
  const { page, counts } = harness();
  page.openImport();
  assert.equal(page.importing, true);
  page.importServer('ss://fixture');
  assert.equal(page.editId, '');
  assert.equal(page.editName, 'Imported');
  page.closeEditor();
  page.openImport();
  await page.importClipboard();
  assert.equal(page.editing, true);
  await page.saveServer();
  page.openImport();
  await page.scanServer();
  assert.equal(page.editName, 'Imported');
  assert.equal(page.importingBusy, false);
  assert.deepEqual(counts(), { clipboardReads: 1, scans: 1 });
  assert.equal(page.selectedId, 'active');
});

test('only the active profile is protected from edit and deletion', async () => {
  const { page, active, other, saves, dialogs } = harness();
  page.openEditor(active);
  assert.equal(page.editing, false);
  page.confirmDelete(active);
  await page.deleteServer(active);
  assert.equal(dialogs.length, 0);
  assert.equal(saves.length, 0);
  page.openEditor(other);
  page.editName = 'Renamed';
  await page.saveServer();
  assert.equal(page.servers.find(server => server.id === 'other').name, 'Renamed');
  page.confirmDelete(other);
  assert.equal(dialogs.length, 1);
  await page.deleteServer(other);
  assert.equal(page.servers.length, 1);
  assert.equal(page.selectedId, 'active');
});

test('save and delete recheck active state after editor/dialog was opened', async () => {
  const { page, other, saves, dialogs } = harness(false);
  page.openEditor(other);
  page.confirmDelete(other);
  page.requested = true;
  page.selectedId = other.id;
  page.editName = 'Must not save';
  await page.saveServer();
  dialogs[0].secondaryButton.action();
  assert.equal(saves.length, 0);
  assert.ok(page.formError.includes('VPN'));
  assert.equal(page.servers.length, 2);
});

test('connected node and mode switching remain locked; cancel/failure leave profiles intact', async () => {
  const { page, active, other, saves, fail } = harness();
  await page.choose(other);
  await page.changeRoute('gfwlist');
  assert.equal(page.selectedId, active.id);
  assert.equal(page.routeMode, 'global');
  page.duplicateServer(active);
  page.closeEditor();
  assert.equal(page.editPassword, '');
  assert.equal(saves.length, 0);
  page.openEditor(other);
  page.editName = 'Unsaved';
  fail();
  await page.saveServer();
  assert.equal(other.name, 'Other');
  assert.equal(page.saving, false);
  assert.equal(page.editing, true);
  assert.equal(page.selectedId, active.id);
});

test('traffic follows the active server ID and live speed disappears after disconnect', () => {
  const { page, setConnection } = harness();
  setConnection({ phase: 'connected', serverId: 'other', updatedAt: 1234,
    traffic: { uploadedBytes: 300, downloadedBytes: 400, uploadSpeed: 20, downloadSpeed: 40 } });
  page.pollStatus();
  assert.equal(page.trafficServerId, 'other');
  assert.equal(page.selectedId, 'other');
  assert.equal(page.speedText(), '上传 20 B/s\n下载 40 B/s');
  assert.equal(page.usageText('active'), '累计上传 100 B\n累计下载 200 B');
  assert.equal(page.usageText('other'), '累计上传 300 B\n累计下载 400 B');
  setConnection({ phase: 'connected', serverId: 'other', updatedAt: 1234, trafficError: 'statistics error' });
  page.pollStatus();
  assert.equal(page.speedText(), '速度暂不可用');
  assert.equal(page.usageText('other'), '累计上传 300 B\n累计下载 400 B');
  setConnection({ phase: 'disconnected', serverId: '', updatedAt: 0 });
  page.pollStatus();
  assert.equal(page.liveTraffic, undefined);
  assert.equal(page.trafficServerId, '');
  assert.equal(page.usageText('other'), '累计上传 300 B\n累计下载 400 B');
});

test('plus menu opens manual, QR and link flows without switching the connected server', async () => {
  const { page, counts } = harness();
  const menu = page.addServerMenu();
  menu[0].action();
  assert.equal(page.editing, true);
  assert.equal(page.editId, '');
  page.closeEditor();
  menu[2].action();
  assert.equal(page.importing, true);
  page.closeImport();
  menu[1].action();
  assert.equal(page.importing, false);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(counts().scans, 1);
  assert.equal(page.editing, true);
  assert.equal(page.editName, 'Imported');
  assert.equal(page.selectedId, 'active');
  page.closeEditor();
  page.busy = true;
  menu.forEach(item => item.action());
  assert.equal(page.editing, false);
  assert.equal(page.importing, false);
  assert.equal(counts().scans, 1);
});

test('direct scanner cancellation and errors stay on the server list', async () => {
  for (const outcome of ['cancel', 'failure', 'unsupported', 'invalid']) {
    const { page, scanState } = harness();
    if (outcome === 'cancel') scanState.error = { code: 1000500002 };
    if (outcome === 'failure') scanState.error = { code: 100 };
    if (outcome === 'unsupported') scanState.supported = false;
    if (outcome === 'invalid') scanState.invalidLink = true;
    await page.scanServer();
    assert.equal(page.importing, false);
    assert.equal(page.editing, false);
    assert.equal(page.importingBusy, false);
    assert.equal(page.importError, '');
    assert.equal(Boolean(page.error), outcome !== 'cancel');
  }
  const { page, scanState } = harness();
  page.openImport();
  scanState.error = { code: 100 };
  await page.scanServer();
  assert.equal(page.importing, true);
  assert.ok(page.importError);
});