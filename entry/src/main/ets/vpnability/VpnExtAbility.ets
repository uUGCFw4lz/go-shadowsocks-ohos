import { Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appendLog, readVpnStopRequest, writeConnectionState } from '../model/AppLog';
import { isRouteMode, RoutingStore } from '../model/RoutingStore';
import { ServerTraffic, TrafficBytes, TrafficSample, TrafficSession, TrafficStore } from '../model/TrafficStore';
import {
  DEFAULT_SS_URL,
  DNS_TUN_PORT,
  DNS_TUN_PORT2,
  SOCKS_HOST,
  SOCKS_PORT,
  TUN_ADDR,
  TUN_GW,
  TUN_MTU
} from '../model/SsConfig';

const DOMAIN = 0x3200;
const TAG = 'ssvpn';

export default class VpnExtAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  private vpnId: string = '';
  private tunFd: number = -1;
  private ssUrl: string = DEFAULT_SS_URL;
  private serverId: string = '';
  private routeMode: string = 'global';
  private phase: string = 'connecting';
  private heartbeat: number = -1;
  private trafficSession: TrafficSession | undefined = undefined;
  private trafficReader: (() => TrafficBytes) | undefined = undefined;
  private trafficEntries: ServerTraffic[] = [];
  private traffic: TrafficSample | undefined = undefined;
  private trafficError: string = '';
  private connectionError: string = '';
  private destroyed: boolean = false;
  private sessionId: string = '';
  private stopRequestId: string = '';
  private starting: Promise<void> | undefined = undefined;
  private stopping: Promise<void> | undefined = undefined;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onCreate');
    appendLog(this.context, 'VpnExtAbility onCreate');
    this.sessionId = util.generateRandomUUID();
    const selectedId = want.parameters?.serverId;
    this.serverId = typeof selectedId === 'string' ? selectedId : '';
    const mode = want.parameters?.routeMode;
    this.routeMode = mode === undefined ? 'global' : (typeof mode === 'string' ? mode : '');
    this.publishState();
    this.heartbeat = setInterval(() => {
      this.sampleTraffic();
      const requestId = readVpnStopRequest(this.context, this.sessionId);
      if (requestId && requestId !== this.stopRequestId && this.phase !== 'disconnecting') {
        this.stopRequestedVpn(requestId);
      } else {
        this.publishState();
      }
    }, 1000);
    const param = want.parameters?.ssUrl;
    if (typeof param === 'string' && param.length > 0) {
      this.ssUrl = param;
    }
    this.starting = this.startPipeline().catch(async (err: BusinessError | Error) => {
      if (this.destroyed || this.stopRequestId) {
        appendLog(this.context, 'VPN startup cancelled during disconnect');
        return;
      }
      const msg = err instanceof Error ? `${err.name} ${err.message}` : JSON.stringify(err);
      this.connectionError = err instanceof Error ? err.message : '';
      hilog.error(DOMAIN, TAG, 'startPipeline failed %{public}s', msg);
      appendLog(this.context, `startPipeline failed: ${msg}`);
      try {
        await this.stopPipeline();
      } catch (cleanupError) {
        appendLog(this.context, `VPN failure cleanup failed: ${JSON.stringify(cleanupError)}`);
      }
      if (!this.destroyed && !this.stopRequestId) {
        this.phase = 'failed';
        this.publishState();
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onDestroy');
    appendLog(this.context, 'VpnExtAbility onDestroy');
    this.destroyed = true;
    if (this.heartbeat !== -1) {
      clearInterval(this.heartbeat);
      this.heartbeat = -1;
    }
    if (this.phase !== 'disconnected' && this.phase !== 'disconnecting') {
      this.sampleTraffic();
      this.stopRequestedVpn(this.stopRequestId);
    }
  }

  private stopRequestedVpn(requestId: string): void {
    this.stopRequestId = requestId;
    this.connectionError = '';
    this.phase = 'disconnecting';
    this.publishState();
    this.finishStop().catch((err: BusinessError | Error) => {
      appendLog(this.context, `VPN destruction failed: ${JSON.stringify(err)}`);
      this.connectionError = 'VPN 断开失败，请查看诊断日志';
      this.phase = 'stop-failed';
      this.publishState();
    });
  }

  private ensureActive(): void {
    if (this.destroyed || this.stopRequestId) {
      throw new Error('VPN startup cancelled');
    }
  }

  private async finishStop(): Promise<void> {
    await this.starting;
    await this.stopPipeline();
    this.phase = 'disconnected';
    this.publishState();
  }

  private publishState(): void {
    writeConnectionState(this.context, this.phase, this.serverId,
      this.phase === 'connected' ? this.traffic : undefined, this.trafficError, this.connectionError,
      this.sessionId, this.stopRequestId);
  }

  private reportTrafficError(err: Error | BusinessError): void {
    const message = err instanceof Error ? err.message : JSON.stringify(err);
    if (!this.trafficError) {
      appendLog(this.context, `traffic statistics failed: ${message}`);
    }
    this.trafficError = '流量统计不可用，请查看诊断日志';
    this.traffic = undefined;
  }

  private sampleTraffic(): void {
    if (this.phase !== 'connected' || !this.trafficSession || !this.trafficReader) {
      return;
    }
    try {
      const sample = this.trafficSession.sample(this.trafficReader(),
        systemDateTime.getUptime(systemDateTime.TimeType.STARTUP));
      const entry: ServerTraffic = {
        serverId: this.serverId, uploadedBytes: sample.uploadedBytes, downloadedBytes: sample.downloadedBytes
      };
      const entries = this.trafficEntries.filter((item: ServerTraffic) => item.serverId !== this.serverId);
      entries.push(entry);
      const previous = this.trafficEntries.find((item: ServerTraffic) => item.serverId === this.serverId);
      if (!previous || previous.uploadedBytes !== entry.uploadedBytes || previous.downloadedBytes !== entry.downloadedBytes) {
        TrafficStore.save(this.context, entries);
        this.trafficEntries = entries;
      }
      this.traffic = sample;
      this.trafficError = '';
    } catch (err) {
      this.reportTrafficError(err);
    }
  }

  private async startPipeline(): Promise<void> {
    if (!isRouteMode(this.routeMode)) {
      throw new Error('无效的路由模式');
    }
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    appendLog(this.context, 'createVpnConnection ok');

    try {
      await this.vpnConnection.protectProcessNet();
      appendLog(this.context, 'protectProcessNet ok');
    } catch (err) {
      if (this.routeMode !== 'global') {
        throw new Error('分流需要成功保护 VPN 出站套接字');
      }
      appendLog(this.context, `protectProcessNet skipped: ${JSON.stringify(err)}`);
    }

    this.ensureActive();
    await this.startSsEngine();
    this.ensureActive();
    this.vpnId = await this.vpnConnection.generateVpnId();
    this.ensureActive();

    const config: vpnExtension.VpnConfig = {
      vpnId: this.vpnId,
      addresses: [{
        address: { address: TUN_ADDR, family: 1 },
        prefixLength: 24
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: { address: '0.0.0.0', family: 1, port: 0 },
          prefixLength: 0
        },
        gateway: { address: TUN_GW, family: 1, port: 0 },
        hasGateway: true,
        isDefaultRoute: true
      }],
      dnsAddresses: ['8.8.8.8', '8.8.4.4'],
      mtu: TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      blockedApplications: ['org.ohos.shadowsocks']
    };

    try {
      this.tunFd = await this.vpnConnection.create(config);
    } catch (err) {
      const error = err as BusinessError;
      if (error.code === 2203002) {
        throw new Error('系统已有 VPN 连接（2203002），请在系统设置中检查 VPN 状态');
      }
      throw new Error(`VPN create failed (${error.code}): ${error.message}`);
    }
    this.ensureActive();
    appendLog(this.context, `vpn create ok tunFd=${this.tunFd} dns=8.8.8.8 via tun2socks :53->127.0.0.1:${DNS_TUN_PORT}`);

    await this.startTun2socks();
    this.ensureActive();
    this.phase = 'connected';
    this.sampleTraffic();
    this.publishState();
  }

  private async startSsEngine(): Promise<void> {
    const nativeMod = await import('../model/NativeBridge');
    this.ensureActive();
    const native = nativeMod.getNative();
    const st = typeof native.engineStatus === 'function' ? native.engineStatus() : 'n/a';
    appendLog(this.context, `native module loaded engineStatus=${st}`);

    const logDir = this.context.getApplicationContext().filesDir;
    const socksAddr = `${SOCKS_HOST}:${SOCKS_PORT}`;
    const dnsTun =
      `127.0.0.1:${DNS_TUN_PORT}=8.8.8.8:53,127.0.0.1:${DNS_TUN_PORT2}=8.8.4.4:53`;
    const routePath = RoutingStore.prepare(this.context, this.routeMode);
    native.startSsClient(this.ssUrl, socksAddr, dnsTun, dnsTun, `${logDir}/ss.log`, routePath);
    appendLog(this.context, `route mode=${this.routeMode}`);
    appendLog(this.context, `ss client started in-process socks=${socksAddr}`);

    const socksReady = native.waitPort(SOCKS_HOST, SOCKS_PORT, 8000);
    appendLog(this.context, `socks ready=${socksReady}`);
    if (!socksReady) {
      throw new Error('SOCKS5 127.0.0.1:1080 not ready');
    }

    const probeHost = this.routeMode === 'china-list' ? 'www.baidu.com' : 'www.google.com';
    const probe = native.socksHttpGet(SOCKS_HOST, SOCKS_PORT, probeHost, 80, 12000);
    appendLog(this.context, `socks probe ${probeHost}: ${probe}`);
    if (probe.indexOf('ok ') !== 0) {
      throw new Error(`SOCKS5 ${probeHost} probe failed: ${probe}`);
    }

    const dnsProbe = native.dnsQuery(SOCKS_HOST, DNS_TUN_PORT, probeHost, 8000);
    appendLog(this.context, `dns tun :${DNS_TUN_PORT} ${probeHost}: ${dnsProbe}`);
    if (dnsProbe.indexOf('ok ') !== 0) {
      throw new Error(`DNS tunnel 127.0.0.1:${DNS_TUN_PORT} failed: ${dnsProbe}`);
    }
    appendLog(this.context, 'SOCKS+DNS ok, creating VPN');
  }

  private async startTun2socks(): Promise<void> {
    const nativeMod = await import('../model/NativeBridge');
    this.ensureActive();
    const native = nativeMod.getNative();
    try {
      if (!this.serverId) {
        throw new Error('Missing server ID for traffic statistics');
      }
      this.trafficEntries = TrafficStore.load(this.context);
      const saved = this.trafficEntries.find((item: ServerTraffic) => item.serverId === this.serverId);
      this.trafficReader = native.getTrafficStats;
      this.trafficSession = new TrafficSession(saved ?? { uploadedBytes: 0, downloadedBytes: 0 },
        this.trafficReader(), systemDateTime.getUptime(systemDateTime.TimeType.STARTUP));
    } catch (err) {
      this.reportTrafficError(err);
    }
    const logDir = this.context.getApplicationContext().filesDir;
    native.clearCloexec(this.tunFd);
    appendLog(this.context, `start tun2socks in-process tunFd=${this.tunFd}`);
    native.startTun2Socks(
      this.tunFd,
      `${SOCKS_HOST}:${SOCKS_PORT}`,
      TUN_MTU,
      `127.0.0.1:${DNS_TUN_PORT}`,
      `${logDir}/t2s.log`
    );
    appendLog(this.context, 'tun2socks started in-process');
  }

  private stopPipeline(): Promise<void> {
    if (this.stopping) {
      return this.stopping;
    }
    const connection = this.vpnConnection;
    if (!connection || !this.vpnId) {
      return Promise.resolve();
    }
    this.stopping = connection.destroy(this.vpnId).then(() => {
      this.tunFd = -1;
      this.vpnId = '';
      appendLog(this.context, 'vpn destroy ok');
    }).finally(() => { this.stopping = undefined; });
    return this.stopping;
  }
}
