import {
  waitPort,
  socksHttpGet,
  dnsQuery,
  clearCloexec
} from 'libentry.so';
import {
  startSsClient,
  startTun2Socks,
  engineStatus,
  setEnginePath
} from 'libssengine.so';

export interface NativeApi {
  startSsClient: (ssUrl: string, socksAddr: string, udpTun: string, tcpTun: string, logPath: string, routePath?: string) => boolean;
  startTun2Socks: (tunFd: number, socksAddr: string, mtu: number, dns: string, logPath: string) => boolean;
  waitPort: (host: string, port: number, timeoutMs: number) => boolean;
  socksHttpGet: (socksHost: string, socksPort: number, destHost: string, destPort: number, timeoutMs: number) => string;
  dnsQuery: (host: string, port: number, name: string, timeoutMs: number) => string;
  clearCloexec: (fd: number) => number;
  setEnginePath: (path: string) => boolean;
  engineStatus?: () => string;
}

export function getNative(): NativeApi {
  if (typeof waitPort !== 'function') {
    throw new Error('libentry.so.waitPort missing');
  }
  if (typeof startSsClient !== 'function') {
    throw new Error('libssengine.so.startSsClient missing');
  }
  return {
    startSsClient,
    startTun2Socks,
    waitPort,
    socksHttpGet,
    dnsQuery,
    clearCloexec,
    setEnginePath,
    engineStatus
  };
}
