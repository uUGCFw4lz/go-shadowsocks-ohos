const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function harness() {
  const files = new Map();
  const prefs = new Map();
  const state = { replies: [], destroyed: 0, failRename: false };
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: filename => ({ fd: filename }),
    writeSync: (fd, text) => { files.set(fd, text); return Buffer.byteLength(text); },
    closeSync: () => {},
    renameSync: (from, to) => {
      if (state.failRename) throw new Error('disk failure');
      files.set(to, files.get(from));
      files.delete(from);
    },
    readTextSync: filename => {
      if (!files.has(filename)) throw new Error('missing file');
      return files.get(filename);
    },
    statSync: filename => ({ size: Buffer.byteLength(fileIo.readTextSync(filename)) })
  };
  const util = {
    Base64Helper: class { decodeSync(text) { return Buffer.from(text, 'base64'); } },
    TextDecoder: { create: (_encoding, options) => ({ decodeToString: data => new TextDecoder('utf-8', options).decode(data) }) }
  };
  const http = {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 0 },
    createHttp: () => ({
      request: async (_source, options) => {
        assert.equal(options.maxLimit, 4 * 1024 * 1024);
        const reply = state.replies.shift();
        if (!reply || reply instanceof Error) throw reply || new Error('offline');
        return reply;
      },
      destroy: () => { state.destroyed++; }
    })
  };
  const preferences = {
    getPreferences: async () => ({
      get: async (key, fallback) => prefs.get(key) ?? fallback,
      put: async (key, value) => prefs.set(key, value), flush: async () => {}
    })
  };
  const imports = {
    '@kit.ArkData': { preferences }, '@kit.ArkTS': { util, url: { URL } },
    '@kit.CoreFileKit': { fileIo }, '@kit.NetworkKit': { http }
  };
  const filename = path.join(__dirname, '../main/ets/model/RoutingStore.ets');
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(source, { exports, require: name => {
    assert.ok(name in imports, name);
    return imports[name];
  } }, { filename });
  return { ...exports, files, state, context: { getApplicationContext: () => ({ filesDir: '/virtual' }) } };
}

const list = '[AutoProxy 0.2.9]\n||example.com\n.example.com\n@@||safe.example.com\n|https://blocked.test/path\n/regex.*/\n@@https://blocked.test/safe';

test('normalizes Base64 and plain domain lists identically', () => {
  const { parseGfwList } = harness();
  for (const content of [list, Buffer.from(list).toString('base64')]) {
    const rules = parseGfwList(content);
    assert.equal(rules.domainCount, 2);
    assert.equal(rules.exceptionCount, 1);
    assert.equal(rules.skipped, 2);
    assert.ok(rules.content.includes('@@||safe.example.com'));
  }
  for (const content of ['', '<html>error</html>', '[AutoProxy 0.2.9]\n! empty']) {
    assert.throws(() => parseGfwList(content));
  }
});

test('persists mode, requires a list, and retries another mirror', async () => {
  const { RoutingStore, state, files, context } = harness();
  assert.equal(await RoutingStore.mode(context), 'global');
  assert.throws(() => RoutingStore.prepare(context, 'gfwlist'));
  state.replies = [new Error('offline'), { responseCode: 200, result: list }];
  const saved = await RoutingStore.update(context);
  assert.equal(saved.domainCount, 2);
  assert.equal(state.destroyed, 2);
  await RoutingStore.saveMode(context, 'gfwlist');
  assert.equal(await RoutingStore.mode(context), 'gfwlist');
  const config = JSON.parse(files.get(RoutingStore.prepare(context, 'gfwlist')));
  assert.equal(config.mode, 'gfwlist');
  assert.equal(config.listPath, RoutingStore.listPath(context));
});

test('network, invalid content and disk failure preserve the old list', async () => {
  const { RoutingStore, state, files, context } = harness();
  state.replies = [{ responseCode: 200, result: list }];
  await RoutingStore.update(context);
  const filename = RoutingStore.listPath(context);
  const previous = files.get(filename);
  for (const result of ['offline', 'invalid', 'disk']) {
    state.failRename = result === 'disk';
    state.replies = Array(4).fill(result === 'offline' ? new Error('offline') : {
      responseCode: 200, result: result === 'invalid' ? '<html>error</html>' : list
    });
    await assert.rejects(() => RoutingStore.update(context));
    assert.equal(files.get(filename), previous);
  }
});

test('built-in modes persist and prepare without downloading GFWList', async () => {
  const { RoutingStore, ROUTE_MODES, context, files, state } = harness();
  for (const mode of ['bypass-lan', 'bypass-china', 'bypass-lan-china', 'china-list']) {
    assert.ok(ROUTE_MODES.some(option => option.id === mode));
    await RoutingStore.saveMode(context, mode);
    assert.equal(await RoutingStore.mode(context), mode);
    const config = JSON.parse(files.get(RoutingStore.prepare(context, mode)));
    assert.equal(config.mode, mode);
  }
  assert.equal(state.destroyed, 0);
  await assert.rejects(() => RoutingStore.saveMode(context, 'unsupported'));
  assert.throws(() => RoutingStore.prepare(context, 'unsupported'));
  assert.equal(await RoutingStore.mode(context), 'china-list');
});

test('real GFWList agrees with native domain projection', { skip: !process.env.GFWLIST_TEST_FILE }, () => {
  const { parseGfwList } = harness();
  const rules = parseGfwList(fs.readFileSync(process.env.GFWLIST_TEST_FILE, 'utf8'));
  assert.ok(rules.domainCount > 1000);
  assert.ok(rules.content.includes('||google.com'));
  assert.ok(rules.content.includes('@@||fonts.googleapis.com'));
  console.log(`real list: proxy=${rules.domainCount} exceptions=${rules.exceptionCount} skipped=${rules.skipped}`);
});