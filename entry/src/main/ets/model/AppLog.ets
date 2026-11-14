import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TrafficSample } from './TrafficStore';

const DOMAIN = 0x3200;
const LOG_NAME = 'vpn.log';

export interface ConnectionState {
  phase: string;
  serverId: string;
  updatedAt: number;
  traffic?: TrafficSample;
  trafficError?: string;
}

export function writeConnectionState(context: common.Context, phase: string, serverId: string,
  traffic?: TrafficSample, trafficError?: string): void {
  const state: ConnectionState = {
    phase: phase, serverId: serverId, updatedAt: Date.now(), traffic: traffic, trafficError: trafficError
  };
  const path = `${appFilesDir(context)}/connection-state.json`;
  try {
    const file = fs.openSync(`${path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(state));
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(`${path}.tmp`, path);
  } catch (err) {
    hilog.error(DOMAIN, 'ssvpn', 'writeConnectionState fail %{public}s', JSON.stringify(err));
  }
}

export function readConnectionState(context: common.Context): ConnectionState {
  try {
    const state = JSON.parse(fs.readTextSync(`${appFilesDir(context)}/connection-state.json`)) as ConnectionState;
    const timeout = state.phase === 'connecting' ? 45000 : 5000;
    if (Date.now() - state.updatedAt < timeout) {
      return state;
    }
  } catch (_) {
  }
  return { phase: 'disconnected', serverId: '', updatedAt: 0 };
}

function appFilesDir(context: common.Context): string {
  return context.getApplicationContext().filesDir;
}

export function logPath(context: common.Context): string {
  return `${appFilesDir(context)}/${LOG_NAME}`;
}

export function appendLog(context: common.Context, msg: string): void {
  hilog.info(DOMAIN, 'ssvpn', '%{public}s', msg);
  try {
    const dir = appFilesDir(context);
    try {
      fs.mkdirSync(dir, true);
    } catch (_e) {
    }
    const path = `${dir}/${LOG_NAME}`;
    const line = `${new Date().toISOString()} ${msg}\n`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, line);
    fs.closeSync(file);
  } catch (err) {
    hilog.error(DOMAIN, 'ssvpn', 'appendLog fail %{public}s', JSON.stringify(err));
  }
}

export function readLog(context: common.Context, name: string = LOG_NAME): string {
  const path = `${appFilesDir(context)}/${name}`;
  try {
    if (!fs.accessSync(path)) {
      return `${name}: (不存在) ${path}`;
    }
    const content = fs.readTextSync(path);
    const lines = content.split('\n').filter((s: string) => s.length > 0);
    return `${name} (${path}):\n${lines.slice(-40).join('\n')}`;
  } catch (err) {
    return `${name}: 读取失败 ${JSON.stringify(err)}`;
  }
}
