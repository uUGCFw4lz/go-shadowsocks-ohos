export function setEnginePath(path: string): boolean;
export function startSsClient(ssUrl: string, socksAddr: string, udpTun: string, tcpTun: string, logPath: string, routePath?: string): boolean;
export function startTun2Socks(tunFd: number, socksAddr: string, mtu: number, dns: string, logPath: string): boolean;
export function engineStatus(): string;
export interface TrafficStats {
  uploadedBytes: number;
  downloadedBytes: number;
}
export function getTrafficStats(): TrafficStats;
