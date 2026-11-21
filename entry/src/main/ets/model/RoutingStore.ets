import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util, url } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

export const GFWLIST_URLS: string[] = [
  'https://gcore.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt',
  'https://testingcf.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt',
  'https://fastly.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt',
  'https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt'
];
const MAX_LIST_SIZE = 4 * 1024 * 1024;

export interface RouteModeOption {
  id: string;
  label: string;
}

export const ROUTE_MODES: RouteModeOption[] = [
  { id: 'global', label: '全局' },
  { id: 'bypass-lan', label: '绕过局域网地址' },
  { id: 'bypass-china', label: '绕过中国大陆地址' },
  { id: 'bypass-lan-china', label: '绕过局域网及中国大陆地址' },
  { id: 'gfwlist', label: 'GFW列表' },
  { id: 'china-list', label: '仅代理中国大陆地址' }
];

export function isRouteMode(mode: string): boolean {
  return ROUTE_MODES.some((option: RouteModeOption) => option.id === mode);
}

export interface GfwRules {
  content: string;
  domainCount: number;
  exceptionCount: number;
  skipped: number;
}

export interface GfwSnapshot extends GfwRules {
  updatedAt: number;
  source: string;
}

interface RoutingConfig {
  mode: string;
  listPath: string;
}

export function parseGfwList(downloaded: string): GfwRules {
  if (downloaded.length === 0 || downloaded.length > MAX_LIST_SIZE) {
    throw new Error('GFWList 文件大小无效');
  }
  let content = downloaded.trim();
  if (!content.startsWith('[AutoProxy')) {
    const decoded = new util.Base64Helper().decodeSync(content.replace(/\s/g, ''));
    content = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(decoded).trim();
  }
  if (!content.startsWith('[AutoProxy')) {
    throw new Error('下载内容不是 GFWList');
  }
  const proxy = new Set<string>();
  const direct = new Set<string>();
  let skipped = 0;
  for (const raw of content.split(/\r?\n/)) {
    let line = raw.trim();
    if (!line || line.startsWith('!') || line.startsWith('[')) {
      continue;
    }
    const exception = line.startsWith('@@');
    if (exception) {
      line = line.substring(2);
    }
    if (line.startsWith('/') || /[$#]/.test(line)) {
      skipped++;
      continue;
    }
    line = line.replace(/^[|.]+/, '').replace(/^\*\./, '');
    if (line.startsWith('http://') || line.startsWith('https://')) {
      try {
        const parsed = new url.URL(line);
        if (exception && parsed.pathname !== '' && parsed.pathname !== '/') {
          skipped++;
          continue;
        }
        line = parsed.hostname;
      } catch (_) {
        skipped++;
        continue;
      }
    } else {
      const boundary = line.search(/[\/^|]/);
      if (boundary >= 0) {
        if (exception && line[boundary] === '/' && line.substring(boundary) !== '/') {
          skipped++;
          continue;
        }
        line = line.substring(0, boundary);
      }
    }
    const host = line.toLowerCase().replace(/\.$/, '');
    const labels = host.split('.');
    if (host.length > 253 || labels.length < 2 || /^[\d.]+$/.test(host) ||
      labels.some((label: string) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
      skipped++;
      continue;
    }
    if (exception) {
      direct.add(host);
    } else {
      proxy.add(host);
    }
  }
  if (proxy.size === 0) {
    throw new Error('GFWList 中没有可用的域名规则');
  }
  const normalized: string[] = ['[AutoProxy 0.2.9]'];
  proxy.forEach((host: string) => { normalized.push(`||${host}`); });
  direct.forEach((host: string) => { normalized.push(`@@||${host}`); });
  return { content: normalized.join('\n'), domainCount: proxy.size, exceptionCount: direct.size, skipped: skipped };
}

function writeAtomic(path: string, text: string): void {
  const file = fs.openSync(`${path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
  fs.renameSync(`${path}.tmp`, path);
}

export class RoutingStore {
  static listPath(context: common.Context): string {
    return `${context.getApplicationContext().filesDir}/gfwlist.json`;
  }

  static async mode(context: common.Context): Promise<string> {
    const store = await preferences.getPreferences(context, 'ss_routing');
    const mode = await store.get('mode', 'global');
    if (typeof mode !== 'string' || !isRouteMode(mode)) {
      throw new Error('无效的路由模式');
    }
    return mode;
  }

  static async saveMode(context: common.Context, mode: string): Promise<void> {
    if (!isRouteMode(mode)) {
      throw new Error('无效的路由模式');
    }
    const store = await preferences.getPreferences(context, 'ss_routing');
    await store.put('mode', mode);
    await store.flush();
  }

  static snapshot(context: common.Context): GfwSnapshot | undefined {
    try {
      const path = RoutingStore.listPath(context);
      if (fs.statSync(path).size > MAX_LIST_SIZE) {
        return undefined;
      }
      const saved = JSON.parse(fs.readTextSync(path)) as GfwSnapshot;
      if (typeof saved.content !== 'string' || !saved.content.startsWith('[AutoProxy') || saved.domainCount <= 0) {
        return undefined;
      }
      return saved;
    } catch (_) {
      return undefined;
    }
  }

  static prepare(context: common.Context, mode: string): string {
    if (!isRouteMode(mode)) {
      throw new Error('无效的路由模式');
    }
    if (mode === 'gfwlist' && !RoutingStore.snapshot(context)) {
      throw new Error('请先更新 GFWList');
    }
    const config: RoutingConfig = { mode: mode, listPath: RoutingStore.listPath(context) };
    const path = `${context.getApplicationContext().filesDir}/routing.json`;
    writeAtomic(path, JSON.stringify(config));
    return path;
  }

  static async update(context: common.Context): Promise<GfwSnapshot> {
    for (const source of GFWLIST_URLS) {
      const request = http.createHttp();
      try {
        const response = await request.request(source, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: 12000,
          maxLimit: MAX_LIST_SIZE,
          usingCache: false,
          usingProxy: false
        });
        if (response.responseCode !== 200 || typeof response.result !== 'string') {
          continue;
        }
        const rules = parseGfwList(response.result);
        const snapshot: GfwSnapshot = {
          content: rules.content, domainCount: rules.domainCount, exceptionCount: rules.exceptionCount,
          skipped: rules.skipped, updatedAt: Date.now(), source: source
        };
        writeAtomic(RoutingStore.listPath(context), JSON.stringify(snapshot));
        return snapshot;
      } catch (_) {
      } finally {
        request.destroy();
      }
    }
    throw new Error('GFWList 更新失败，已保留原有规则');
  }
}