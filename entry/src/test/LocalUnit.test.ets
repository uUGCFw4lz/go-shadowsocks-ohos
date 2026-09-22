import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { CIPHERS, ServerProfile, serverUrl, validateServer } from '../main/ets/model/ServerStore';
import { parseGfwList } from '../main/ets/model/RoutingStore';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    it('normalizesGfwDomainRules', 0, () => {
      const rules = parseGfwList('[AutoProxy 0.2.9]\n||example.com\n.example.com\n@@||safe.example.com\n|https://blocked.test/path\n/regex.*/\n@@https://blocked.test/safe');
      expect(rules.domainCount).assertEqual(2);
      expect(rules.exceptionCount).assertEqual(1);
      expect(rules.skipped).assertEqual(2);
      expect(rules.content.includes('@@||safe.example.com')).assertTrue();
    });
    it('rejectsInvalidGfwDownload', 0, () => {
      let rejected = false;
      try {
        parseGfwList('[AutoProxy 0.2.9]\n! empty list');
      } catch (_) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
    it('acceptsXChaChaServer', 0, () => {
      const server: ServerProfile = {
        id: 'xchacha', name: 'XChaCha', host: 'example.com', port: 8388,
        method: 'xchacha20-ietf-poly1305', password: 'secret'
      };
      expect(CIPHERS.includes(server.method)).assertTrue();
      expect(validateServer(server)).assertEqual('');
      expect(serverUrl(server)).assertEqual('ss://xchacha20-ietf-poly1305:secret@example.com:8388');
      const restored = JSON.parse(JSON.stringify(server)) as ServerProfile;
      expect(restored.method).assertEqual(server.method);
      expect(CIPHERS.indexOf(restored.method) >= 0).assertTrue();
    });
    it('encodesServerCredentialsAndIPv6', 0, () => {
      const server: ServerProfile = {
        id: 'test', name: 'Test', host: '2001:db8::1', port: 8388,
        method: 'aes-256-gcm', password: 'a@b:c/#%'
      };
      expect(serverUrl(server)).assertEqual('ss://aes-256-gcm:a%40b%3Ac%2F%23%25@[2001:db8::1]:8388');
      expect(validateServer(server)).assertEqual('');
    });
    it('rejectsInvalidServerFields', 0, () => {
      const server: ServerProfile = {
        id: 'test', name: 'Test', host: 'example.com', port: 0,
        method: 'aes-128-gcm', password: 'secret'
      };
      expect(validateServer(server).length > 0).assertTrue();
      server.port = 65536;
      expect(validateServer(server).length > 0).assertTrue();
      server.port = 8388;
      server.host = 'https://example.com';
      expect(validateServer(server).length > 0).assertTrue();
      server.host = 'example.com';
      server.password = '';
      expect(validateServer(server).length > 0).assertTrue();
      server.password = 'secret';
      server.method = 'unsupported';
      expect(validateServer(server).length > 0).assertTrue();
    });
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });
  });
}