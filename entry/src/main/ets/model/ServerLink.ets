import { util, url } from '@kit.ArkTS';
import { CIPHERS, ServerProfile, validateServer } from './ServerStore';

const MAX_LINK_LENGTH = 8192;

function encodeBase64(text: string): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(text))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeBase64(text: string): string {
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(text)) {
    throw new Error('ss:// 链接的 Base64 编码无效');
  }
  const unpadded = text.replace(/=+$/, '');
  if (unpadded.length % 4 === 1) {
    throw new Error('ss:// 链接的 Base64 编码无效');
  }
  const padded = unpadded.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - unpadded.length % 4) % 4);
  const bytes = new util.Base64Helper().decodeSync(padded);
  const decoded = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
  if (encodeBase64(decoded) !== unpadded.replace(/\+/g, '-').replace(/\//g, '_')) {
    throw new Error('ss:// 链接的 Base64 编码无效');
  }
  return decoded;
}

function cipherName(method: string): string {
  const aliases: Record<string, string> = {
    'AEAD_CHACHA20_POLY1305': 'chacha20-ietf-poly1305',
    'AEAD_XCHACHA20_POLY1305': 'xchacha20-ietf-poly1305',
    'AEAD_AES_128_GCM': 'aes-128-gcm',
    'AEAD_AES_256_GCM': 'aes-256-gcm'
  };
  const normalized = aliases[method.toUpperCase()] ?? method.toLowerCase();
  if (!CIPHERS.includes(normalized)) {
    throw new Error('此链接使用的加密方式暂不支持');
  }
  return normalized;
}

export function shareServerUrl(server: ServerProfile): string {
  const invalid = validateServer(server);
  if (invalid) {
    throw new Error(invalid);
  }
  const host = server.host.includes(':') ? `[${server.host}]` : server.host;
  const link = `ss://${encodeBase64(`${server.method}:${server.password}`)}@${host}:${server.port}#${encodeURIComponent(server.name)}`;
  if (link.length > MAX_LINK_LENGTH) {
    throw new Error('服务器配置过长，无法生成分享链接');
  }
  return link;
}

export function parseServerUrl(input: string): ServerProfile {
  const link = input.trim();
  if (link.length > MAX_LINK_LENGTH || !/^ss:\/\//i.test(link) || /\s/.test(link)) {
    throw new Error('请提供一条完整的 ss:// 服务器链接');
  }
  let body = link.substring(5);
  let name = '';
  const fragment = body.indexOf('#');
  if (fragment >= 0) {
    try {
      name = decodeURIComponent(body.substring(fragment + 1));
    } catch (_) {
      throw new Error('服务器备注编码无效');
    }
    body = body.substring(0, fragment);
  }
  if (body.includes('?')) {
    throw new Error('暂不支持带插件或扩展参数的 ss:// 链接');
  }
  let credentials = '';
  let endpoint = '';
  let method = '';
  let password = '';
  try {
    if (body.includes('@')) {
      const separator = body.lastIndexOf('@');
      const userinfo = body.substring(0, separator);
      endpoint = body.substring(separator + 1);
      if (userinfo.includes(':')) {
        const colon = userinfo.indexOf(':');
        method = decodeURIComponent(userinfo.substring(0, colon));
        password = decodeURIComponent(userinfo.substring(colon + 1));
      } else {
        credentials = decodeBase64(decodeURIComponent(userinfo));
      }
    } else {
      const decoded = decodeBase64(body);
      const separator = decoded.lastIndexOf('@');
      if (separator < 0) {
        throw new Error('missing endpoint');
      }
      credentials = decoded.substring(0, separator);
      endpoint = decoded.substring(separator + 1);
    }
    if (credentials) {
      const colon = credentials.indexOf(':');
      if (colon < 1) {
        throw new Error('missing credentials');
      }
      method = credentials.substring(0, colon);
      password = credentials.substring(colon + 1);
    }
  } catch (_) {
    throw new Error('ss:// 链接的认证信息无效');
  }
  endpoint = endpoint.replace(/\/$/, '');
  const authority = /^(\[[0-9a-fA-F:.]+\]|[^:@\/\[\]?#%]+):(\d{1,5})$/.exec(endpoint);
  if (!authority) {
    throw new Error('服务器地址或端口无效，IPv6 地址需要方括号');
  }
  let host = authority[1];
  try {
    const parsed = new url.URL(`http://${endpoint}`);
    host = parsed.hostname.replace(/^\[|\]$/g, '');
  } catch (_) {
    throw new Error('服务器地址无效');
  }
  const server: ServerProfile = {
    id: '', name: name.trim() || host.substring(0, 48), host: host,
    port: Number(authority[2]), method: cipherName(method), password: password
  };
  if (server.name.length > 48 || /[\u0000-\u001f\u007f]/.test(server.name)) {
    throw new Error('服务器备注过长或包含控制字符');
  }
  const invalid = validateServer(server);
  if (invalid) {
    throw new Error(invalid);
  }
  return server;
}