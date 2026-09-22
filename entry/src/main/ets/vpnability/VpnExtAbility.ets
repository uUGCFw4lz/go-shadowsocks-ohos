import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appendLog, writeConnectionState } from '../model/AppLog';
import { RoutingStore } from '../model/RoutingStore';
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
  private tunFd: number = -1;
  private ssUrl: string = DEFAULT_SS_URL;
  private serverId: string = '';
  private routeMode: string = 'global';
  private phase: string = 'connecting';
  private heartbeat: number = -1;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onCreate');
    appendLog(this.context, 'VpnExtAbility onCreate');
    const selectedId = want.parameters?.serverId;
    this.serverId = typeof selectedId === 'string' ? selectedId : '';
    this.routeMode = want.parameters?.routeMode === 'gfwlist' ? 'gfwlist' : 'global';
    writeConnectionState(this.context, this.phase, this.serverId);
    this.heartbeat = setInterval(() => writeConnectionState(this.context, this.phase, this.serverId), 1000);
    const param = want.parameters?.ssUrl;
    if (typeof param === 'string' && param.length > 0) {
      this.ssUrl = param;
    }
    this.startPipeline().catch((err: BusinessError | Error) => {
      const msg = err instanceof Error ? `${err.name} ${err.message}` : JSON.stringify(err);
      hilog.error(DOMAIN, TAG, 'startPipeline failed %{public}s', msg);
      appendLog(this.context, `startPipeline failed: ${msg}`);
      this.phase = 'failed';
      writeConnectionState(this.context, this.phase, this.serverId);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onDestroy');
    appendLog(this.context, 'VpnExtAbility onDestroy');
    if (this.heartbeat !== -1) {
      clearInterval(this.heartbeat);
      this.heartbeat = -1;
    }
    this.phase = 'disconnected';
    writeConnectionState(this.context, this.phase, this.serverId);
    this.stopPipeline();
  }

  private async startPipeline(): Promise<void> {
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    appendLog(this.context, 'createVpnConnection ok');

    try {
      await this.vpnConnection.protectProcessNet();
      appendLog(this.context, 'protectProcessNet ok');
    } catch (err) {
      if (this.routeMode === 'gfwlist') {
        throw new Error('GFWList 分流需要成功保护 VPN 出站套接字');
      }
      appendLog(this.context, `protectProcessNet skipped: ${JSON.stringify(err)}`);
    }

    await this.startSsEngine();

    const config: vpnExtension.VpnConfig = {
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

    this.tunFd = await this.vpnConnection.create(config);
    appendLog(this.context, `vpn create ok tunFd=${this.tunFd} dns=8.8.8.8 via tun2socks :53->127.0.0.1:${DNS_TUN_PORT}`);

    await this.startTun2socks();
    this.phase = 'connected';
    writeConnectionState(this.context, this.phase, this.serverId);
  }

  private async startSsEngine(): Promise<void> {
    const nativeMod = await import('../model/NativeBridge');
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

    const probe = native.socksHttpGet(SOCKS_HOST, SOCKS_PORT, 'www.google.com', 80, 12000);
    appendLog(this.context, `socks probe www.google.com: ${probe}`);
    if (probe.indexOf('ok ') !== 0) {
      throw new Error(`SOCKS5 google probe failed: ${probe}`);
    }

    const dnsProbe = native.dnsQuery(SOCKS_HOST, DNS_TUN_PORT, 'www.google.com', 8000);
    appendLog(this.context, `dns tun :${DNS_TUN_PORT} www.google.com: ${dnsProbe}`);
    if (dnsProbe.indexOf('ok ') !== 0) {
      throw new Error(`DNS tunnel 127.0.0.1:${DNS_TUN_PORT} failed: ${dnsProbe}`);
    }
    appendLog(this.context, 'SOCKS+DNS ok, creating VPN');
  }

  private async startTun2socks(): Promise<void> {
    const nativeMod = await import('../model/NativeBridge');
    const native = nativeMod.getNative();
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

  private stopPipeline(): void {
    if (this.vpnConnection) {
      this.vpnConnection.destroy().then(() => {
        appendLog(this.context, 'vpn destroy ok');
      }).catch((err: BusinessError) => {
        appendLog(this.context, `vpn destroy failed ${JSON.stringify(err)}`);
      });
    }
  }
}
