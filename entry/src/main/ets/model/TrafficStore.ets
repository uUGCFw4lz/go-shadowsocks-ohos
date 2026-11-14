import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface TrafficBytes {
  uploadedBytes: number;
  downloadedBytes: number;
}

export interface ServerTraffic extends TrafficBytes {
  serverId: string;
}

export interface TrafficSample extends TrafficBytes {
  uploadSpeed: number;
  downloadSpeed: number;
}

function validBytes(bytes: TrafficBytes): boolean {
  return bytes !== null && typeof bytes === 'object' &&
    Number.isSafeInteger(bytes.uploadedBytes) && bytes.uploadedBytes >= 0 &&
    Number.isSafeInteger(bytes.downloadedBytes) && bytes.downloadedBytes >= 0;
}

export function formatTraffic(bytes: number): string {
  const units: string[] = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let unit = 0;
  while (bytes >= 1024 && unit < units.length - 1) {
    bytes /= 1024;
    unit++;
  }
  return `${bytes.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

export class TrafficSession {
  private previous: TrafficBytes;
  private previousTime: number;
  private total: TrafficBytes;

  constructor(total: TrafficBytes, baseline: TrafficBytes, time: number) {
    if (!validBytes(total) || !validBytes(baseline) || !Number.isFinite(time)) {
      throw new Error('Invalid initial traffic counters');
    }
    this.total = { uploadedBytes: total.uploadedBytes, downloadedBytes: total.downloadedBytes };
    this.previous = baseline;
    this.previousTime = time;
  }

  sample(current: TrafficBytes, time: number): TrafficSample {
    if (!validBytes(current) || current.uploadedBytes < this.previous.uploadedBytes ||
      current.downloadedBytes < this.previous.downloadedBytes || !Number.isFinite(time) || time < this.previousTime) {
      throw new Error('Invalid traffic counter or clock regression');
    }
    const uploaded = current.uploadedBytes - this.previous.uploadedBytes;
    const downloaded = current.downloadedBytes - this.previous.downloadedBytes;
    const seconds = (time - this.previousTime) / 1000;
    const total: TrafficBytes = {
      uploadedBytes: this.total.uploadedBytes + uploaded,
      downloadedBytes: this.total.downloadedBytes + downloaded
    };
    if (!validBytes(total)) {
      throw new Error('Traffic totals exceed supported precision');
    }
    this.total = total;
    this.previous = current;
    this.previousTime = time;
    return {
      uploadedBytes: total.uploadedBytes, downloadedBytes: total.downloadedBytes,
      uploadSpeed: seconds > 0 ? uploaded / seconds : 0,
      downloadSpeed: seconds > 0 ? downloaded / seconds : 0
    };
  }
}

// Only the VPN extension writes totals; the UI reads atomic snapshots across processes.
export class TrafficStore {
  static load(context: common.Context): ServerTraffic[] {
    const path = `${context.getApplicationContext().filesDir}/server-traffic.json`;
    if (!fs.accessSync(path)) {
      return [];
    }
    const entries = JSON.parse(fs.readTextSync(path)) as ServerTraffic[];
    if (!Array.isArray(entries)) {
      throw new Error('Invalid saved traffic totals');
    }
    const ids = new Set<string>();
    for (const entry of entries) {
      if (!validBytes(entry) || typeof entry.serverId !== 'string' || !entry.serverId || ids.has(entry.serverId)) {
        throw new Error('Invalid saved server traffic');
      }
      ids.add(entry.serverId);
    }
    return entries;
  }

  static save(context: common.Context, entries: ServerTraffic[]): void {
    const path = `${context.getApplicationContext().filesDir}/server-traffic.json`;
    const file = fs.openSync(`${path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const text = new util.TextEncoder().encodeInto(JSON.stringify(entries));
      if (fs.writeSync(file.fd, text.buffer) !== text.byteLength) {
        throw new Error('Incomplete traffic totals write');
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(`${path}.tmp`, path);
  }
}
