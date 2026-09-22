import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { url } from '@kit.ArkTS';
import { DEFAULT_SS_URL } from './SsConfig';

export const CIPHERS: string[] = ['xchacha20-ietf-poly1305', 'chacha20-ietf-poly1305', 'aes-128-gcm', 'aes-256-gcm'];

export interface ServerProfile {
  id: string;
  name: string;
  host: string;
  port: number;
  method: string;
  password: string;
}

export interface ServerSettings {
  servers: ServerProfile[];
  selectedId: string;
}

export function serverUrl(server: ServerProfile): string {
  const host = server.host.includes(':') ? `[${server.host}]` : server.host;
  return `ss://${server.method}:${encodeURIComponent(server.password)}@${host}:${server.port}`;
}

export function validateServer(server: ServerProfile): string {
  if (!server.name.trim()) {
    return '请输入服务器名称';
  }
  if (!server.host || /[\s\/@?#\[\]]/.test(server.host)) {
    return '请输入有效的域名或 IP 地址，不要包含协议或路径';
  }
  if (!Number.isInteger(server.port) || server.port < 1 || server.port > 65535) {
    return '端口必须为 1 到 65535 的整数';
  }
  if (CIPHERS.indexOf(server.method) < 0) {
    return '请选择支持的加密方式';
  }
  if (!server.password.length) {
    return '请输入密码';
  }
  return '';
}

export class ServerStore {
  static async load(context: common.Context): Promise<ServerSettings> {
    const store = await preferences.getPreferences(context, 'ss_servers');
    const saved = await store.get('settings', '') as string;
    if (saved) {
      return JSON.parse(saved) as ServerSettings;
    }
    const endpoint = new url.URL(DEFAULT_SS_URL);
    const server: ServerProfile = {
      id: 'original', name: '默认服务器',
      host: endpoint.hostname,
      port: Number(endpoint.port),
      method: 'chacha20-ietf-poly1305',
      password: decodeURIComponent(endpoint.password)
    };
    return { servers: [server], selectedId: server.id };
  }

  static async save(context: common.Context, settings: ServerSettings): Promise<void> {
    const store = await preferences.getPreferences(context, 'ss_servers');
    await store.put('settings', JSON.stringify(settings));
    await store.flush();
  }
}