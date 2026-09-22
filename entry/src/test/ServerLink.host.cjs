const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const util = {
  Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    decodeSync(text) { return Buffer.from(text, 'base64'); }
  },
  TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  TextDecoder: { create: (_encoding, options) => ({ decodeToString: bytes => new TextDecoder('utf-8', options).decode(bytes) }) }
};
function load(filename, imports) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(__dirname, '../main/ets/model', filename), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, { exports, require: name => { assert.ok(name in imports, name); return imports[name]; } });
  return exports;
}
const store = load('ServerStore.ets', {
  '@kit.ArkData': { preferences: {} }, '@kit.ArkTS': { url: { URL } }, './SsConfig': { DEFAULT_SS_URL: '' }
});
const { parseServerUrl, shareServerUrl } = load('ServerLink.ets', {
  '@kit.ArkTS': { util, url: { URL } }, './ServerStore': store
});
const encode = text => Buffer.from(text).toString('base64url');

test('SIP002 round trip for all supported ciphers, unicode and IPv6', () => {
  for (const method of store.CIPHERS) {
    for (const host of ['example.com', '2001:db8::1']) {
      const server = { id: 'existing', name: '东京 #1', host, port: 8388, method, password: '密碼:@/#%+?=' };
      const link = shareServerUrl(server);
      assert.ok(link.startsWith('ss://'));
      assert.ok(!link.includes(server.password));
      const imported = parseServerUrl(link);
      for (const key of ['name', 'host', 'port', 'method', 'password']) assert.equal(imported[key], server[key]);
      assert.equal(imported.id, '');
    }
  }
});

test('imports SIP002 base64, plaintext and legacy full base64', () => {
  const credential = 'aes-256-gcm:p@ss:word';
  for (const link of [
    `ss://${encode(credential)}@example.com:443/#test`,
    `ss://${Buffer.from(credential).toString('base64')}@example.com:443#test`,
    'ss://aes-256-gcm:p%40ss%3Aword@example.com:443#test',
    `ss://${encode(credential + '@example.com:443')}#test`
  ]) {
    const server = parseServerUrl(link);
    assert.equal(server.password, 'p@ss:word');
    assert.equal(server.method, 'aes-256-gcm');
    assert.equal(server.host, 'example.com');
    assert.equal(server.port, 443);
    assert.equal(server.name, 'test');
  }
  assert.equal(parseServerUrl('ss://AEAD_XCHACHA20_POLY1305:test@example.com:8388').method, 'xchacha20-ietf-poly1305');
  assert.equal(parseServerUrl(`ss://${encode('aes-128-gcm:%40literal')}@example.com:80`).password, '%40literal');
});

test('rejects malformed, ambiguous and unsupported links without echoing credentials', () => {
  for (const link of [
    '', 'https://example.com', 'ss://a@example.com:8388',
    'ss://aes-256-gcm:secret@example.com:0', 'ss://aes-256-gcm:secret@example.com:65536',
    'ss://aes-256-gcm:secret@example.com', 'ss://aes-256-gcm:secret@2001:db8::1:8388',
    'ss://aes-256-gcm:secret@[bad::ip]:8388', 'ss://aes-256-gcm:secret@example.com:8388/path',
    'ss://unknown:secret@example.com:8388', 'ss://aes-256-gcm:@example.com:8388',
    'ss://aes-256-gcm:secret@example.com:8388?plugin=v2ray-plugin',
    'ss://aes-256-gcm:secret@example.com:8388#%XY',
    'ss://aes-256-gcm:%XY@example.com:8388',
    'ss://aes-256-gcm:secret@example.com:8388\nss://aes-256-gcm:secret@example.com:443',
    'ss://' + 'a'.repeat(8192)
  ]) {
    assert.throws(() => parseServerUrl(link), error => !error.message.includes('secret'));
  }
});

test('sharing does not alter engine URL or the original profile', () => {
  const server = { id: 'original', name: 'Test', host: '2001:db8::1', port: 8388, method: 'aes-256-gcm', password: 'a@b:c/#%' };
  const original = JSON.stringify(server);
  const engineUrl = store.serverUrl(server);
  const imported = parseServerUrl(shareServerUrl(server));
  assert.equal(JSON.stringify(server), original);
  assert.equal(store.serverUrl(imported), engineUrl);
  assert.equal(engineUrl, 'ss://aes-256-gcm:a%40b%3Ac%2F%23%25@[2001:db8::1]:8388');
  const long = { ...server, password: 'x'.repeat(500) };
  const longLink = shareServerUrl(long);
  assert.ok(longLink.length > 512);
  assert.equal(parseServerUrl(longLink).password, long.password);
  assert.throws(() => shareServerUrl({ ...server, password: 'x'.repeat(8192) }));
});