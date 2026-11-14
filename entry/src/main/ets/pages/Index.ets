import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BUNDLE_NAME, VPN_ABILITY } from '../model/SsConfig';
import { appendLog, ConnectionState, readLog, readConnectionState } from '../model/AppLog';
import { formatTraffic, ServerTraffic, TrafficSample, TrafficStore } from '../model/TrafficStore';
import { CIPHERS, ServerProfile, ServerStore, serverUrl, validateServer } from '../model/ServerStore';
import { RoutingStore } from '../model/RoutingStore';
import { parseServerUrl, shareServerUrl } from '../model/ServerLink';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { systemShare } from '@kit.ShareKit';
import { DARK_THEME, LIGHT_THEME, ThemeMode, ThemePalette, ThemeStore } from '../model/ThemeStore';

@Entry
@Component
struct Index {
  @State servers: ServerProfile[] = [];
  @State selectedId: string = '';
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State requested: boolean = false;
  @State connected: boolean = false;
  @State status: string = '未连接';
  @State error: string = '';
  @State editing: boolean = false;
  @State showLogs: boolean = false;
  @State logText: string = '';
  @State editId: string = '';
  @State editName: string = '';
  @State editHost: string = '';
  @State editPort: string = '8388';
  @State editMethod: number = 0;
  @State editPassword: string = '';
  @State formError: string = '';
  @State saving: boolean = false;
  @State routeMode: string = 'global';
  @State updatingRules: boolean = false;
  @State rulesStatus: string = '尚未下载 GFWList';
  @State rulesReady: boolean = false;
  @State importing: boolean = false;
  @State importText: string = '';
  @State importError: string = '';
  @State importingBusy: boolean = false;
  @State shareLink: string = '';
  @State shareName: string = '';
  @State shareStatus: string = '';
  @State sharingBusy: boolean = false;
  @State themeMode: ThemeMode = 'light';
  @State trafficEntries: ServerTraffic[] = [];
  @State liveTraffic: TrafficSample | undefined = undefined;
  @State trafficServerId: string = '';
  @State trafficError: string = '';
  @State trafficReadFailed: boolean = false;
  private observer: vpnExtension.VpnObserver | undefined = undefined;
  private timer: number = -1;
  private requestTime: number = 0;

  aboutToAppear(): void {
    this.loadTheme();
    this.loadServers();
    this.pollStatus();
    this.timer = setInterval(() => this.pollStatus(), 1000);
    try {
      this.observer = vpnExtension.createVpnObserver();
      this.observer.onAuthorizationResult((allowed: boolean) => {
        if (!allowed) {
          this.requestTime = 0;
          this.requested = false;
          this.status = '未授权';
          this.error = 'VPN 授权已取消';
        }
      });
    } catch (_) {
    }
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    try {
      this.observer?.offAuthorizationResult();
    } catch (_) {
    }
  }

  onBackPress(): boolean {
    if (this.importing) {
      if (!this.importingBusy) {
        this.closeImport();
      }
      return true;
    }
    if (this.shareLink) {
      this.closeShare();
      return true;
    }
    if (this.editing) {
      if (!this.saving) {
        this.closeEditor();
      }
      return true;
    }
    if (this.showLogs) {
      this.showLogs = false;
      return true;
    }
    return false;
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private colors(): ThemePalette {
    return this.themeMode === 'dark' ? DARK_THEME : LIGHT_THEME;
  }

  private async loadTheme(): Promise<void> {
    try {
      const mode = await ThemeStore.mode(this.context());
      ThemeStore.apply(this.context(), mode);
      this.themeMode = mode;
    } catch (_) {
      this.themeMode = 'light';
    }
  }

  private async toggleTheme(): Promise<void> {
    const previous = this.themeMode;
    const mode: ThemeMode = previous === 'dark' ? 'light' : 'dark';
    this.themeMode = mode;
    try {
      await ThemeStore.save(this.context(), mode);
    } catch (_) {
      this.themeMode = previous;
      this.error = '主题设置保存失败';
    }
  }

  private async loadServers(): Promise<void> {
    try {
      this.routeMode = await RoutingStore.mode(this.context());
      this.refreshRules();
      const settings = await ServerStore.load(this.context());
      this.servers = settings.servers;
      this.selectedId = this.servers.some((server: ServerProfile) => server.id === settings.selectedId) ?
        settings.selectedId : (this.servers.length ? this.servers[0].id : '');
      this.ready = true;
    } catch (_) {
      this.error = '无法读取服务器配置，请重新打开应用';
    }
  }

  private selected(): ServerProfile | undefined {
    return this.servers.find((server: ServerProfile) => server.id === this.selectedId);
  }

  private canManageServers(): boolean {
    return this.ready && !this.busy && !this.saving;
  }

  private serverInUse(id: string): boolean {
    return id !== '' && this.requested && id === this.selectedId;
  }

  private refreshRules(): void {
    const snapshot = RoutingStore.snapshot(this.context());
    this.rulesReady = snapshot !== undefined;
    if (!snapshot) {
      this.rulesStatus = '尚未下载 GFWList';
      return;
    }
    const updated = new Date(snapshot.updatedAt);
    const date = `${updated.getFullYear()}/${String(updated.getMonth() + 1).padStart(2, '0')}/${String(updated.getDate()).padStart(2, '0')}`;
    const time = `${String(updated.getHours()).padStart(2, '0')}:${String(updated.getMinutes()).padStart(2, '0')}:${String(updated.getSeconds()).padStart(2, '0')}`;
    this.rulesStatus = `${snapshot.domainCount} 域名 · ${snapshot.exceptionCount} 例外 · 跳过 ${snapshot.skipped}\n${date} ${time}`;
  }

  private async changeRoute(mode: string): Promise<void> {
    if (!this.ready || this.requested || this.busy || this.updatingRules || mode === this.routeMode) {
      return;
    }
    this.busy = true;
    try {
      await RoutingStore.saveMode(this.context(), mode);
      this.routeMode = mode;
      this.error = '';
    } catch (_) {
      this.error = '路由模式保存失败';
    } finally {
      this.busy = false;
    }
  }

  private async updateRules(): Promise<void> {
    if (this.updatingRules || this.busy) {
      return;
    }
    this.updatingRules = true;
    this.error = '';
    try {
      await RoutingStore.update(this.context());
      this.refreshRules();
      if (this.requested) {
        this.rulesStatus += ' · 下次连接生效';
      }
    } catch (_) {
      this.error = 'GFWList 更新失败，原有规则未更改';
    } finally {
      this.updatingRules = false;
    }
  }

  private pollStatus(): void {
    const state = readConnectionState(this.context());
    if (this.requestTime > state.updatedAt && Date.now() - this.requestTime < 35000) {
      return;
    }
    this.connected = state.phase === 'connected';
    this.requested = this.connected || state.phase === 'connecting';
    this.status = this.connected ? '已连接' : (this.requested ? '正在连接' : '未连接');
    this.refreshTraffic(state);
    if (this.requested && state.serverId && this.servers.some((server: ServerProfile) => server.id === state.serverId)) {
      this.selectedId = state.serverId;
    }
    if (state.phase === 'failed') {
      this.status = '连接失败';
      this.error = '服务器连接失败，请检查配置或查看诊断日志';
    }
  }

  private refreshTraffic(state: ConnectionState): void {
    this.liveTraffic = this.connected ? state.traffic : undefined;
    this.trafficServerId = this.connected ? state.serverId : '';
    try {
      this.trafficEntries = TrafficStore.load(this.context());
      this.trafficReadFailed = false;
      this.trafficError = state.trafficError ?? '';
    } catch (err) {
      if (!this.trafficError) {
        appendLog(this.context(), `read traffic totals failed: ${JSON.stringify(err)}`);
      }
      this.trafficReadFailed = true;
      this.trafficError = '流量统计读取失败，请查看诊断日志';
    }
  }

  private usageText(id: string): string {
    const saved = this.trafficEntries.find((item: ServerTraffic) => item.serverId === id);
    if (this.trafficReadFailed) {
      return '累计流量暂不可用';
    }
    return `累计上传 ${formatTraffic(saved?.uploadedBytes ?? 0)}\n累计下载 ${formatTraffic(saved?.downloadedBytes ?? 0)}`;
  }

  private speedText(): string {
    if (!this.liveTraffic || this.trafficError) {
      return this.trafficError ? '速度暂不可用' : '正在读取速度';
    }
    return `上传 ${formatTraffic(this.liveTraffic.uploadSpeed)}/s\n下载 ${formatTraffic(this.liveTraffic.downloadSpeed)}/s`;
  }

  private async choose(server: ServerProfile): Promise<void> {
    if (this.requested || !this.canManageServers()) {
      return;
    }
    this.busy = true;
    try {
      await ServerStore.save(this.context(), { servers: this.servers, selectedId: server.id });
      this.selectedId = server.id;
      this.error = '';
    } catch (_) {
      this.error = '选择未保存，请重试';
    } finally {
      this.busy = false;
    }
  }

  private openEditor(server?: ServerProfile, asCopy: boolean = false): void {
    if (!this.canManageServers() || (!asCopy && this.serverInUse(server?.id ?? ''))) {
      return;
    }
    this.editId = asCopy ? '' : (server?.id ?? '');
    this.editName = asCopy && server ? `${server.name.substring(0, 45)} 副本` : (server?.name ?? '');
    this.editHost = server?.host ?? '';
    this.editPort = server ? `${server.port}` : '8388';
    this.editMethod = server ? CIPHERS.indexOf(server.method) : 0;
    this.editPassword = server?.password ?? '';
    this.formError = '';
    this.editing = true;
  }

  private duplicateServer(server: ServerProfile): void {
    this.openEditor(server, true);
  }

  private closeEditor(): void {
    this.editing = false;
    this.editPassword = '';
  }

  private openImport(): void {
    if (!this.canManageServers()) {
      return;
    }
    this.importText = '';
    this.importError = '';
    this.importing = true;
  }

  private closeImport(): void {
    this.importing = false;
    this.importText = '';
    this.importError = '';
  }

  private importServer(link: string): void {
    if (!this.canManageServers()) {
      this.importError = '配置正在处理中，请稍后重试';
      return;
    }
    try {
      const server = parseServerUrl(link);
      this.closeImport();
      this.openEditor(server);
    } catch (err) {
      this.importError = err instanceof Error ? err.message : '服务器链接无效';
    }
  }

  private async importClipboard(): Promise<void> {
    if (this.importingBusy || !this.canManageServers()) {
      return;
    }
    this.importingBusy = true;
    this.importError = '';
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      this.importServer(data.getPrimaryText());
    } catch (_) {
      this.importError = '无法读取剪贴板，请重新点击粘贴或手动输入链接';
    } finally {
      this.importingBusy = false;
    }
  }

  private async scanServer(): Promise<void> {
    if (this.importingBusy || !this.canManageServers()) {
      return;
    }
    this.importingBusy = true;
    this.importError = '';
    try {
      if (typeof scanCore.isDefaultScanSupported === 'function' && !scanCore.isDefaultScanSupported()) {
        this.importError = '此设备不支持系统扫码，请使用粘贴导入';
        return;
      }
      const result = await scanBarcode.startScanForResult(this.context(), {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      });
      this.importServer(result.originalValue);
    } catch (err) {
      const code = (err as BusinessError).code;
      if (code !== scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
        this.importError = `无法打开系统扫码（${code ?? '未知错误'}），请重试或使用粘贴导入`;
      }
    } finally {
      this.importingBusy = false;
    }
  }

  private openShare(server: ServerProfile): void {
    try {
      this.shareLink = shareServerUrl(server);
      this.shareName = server.name;
      this.shareStatus = '';
    } catch (_) {
      this.error = '配置无效或过长，无法分享';
    }
  }

  private closeShare(): void {
    this.shareLink = '';
    this.shareName = '';
    this.shareStatus = '';
  }

  private async copyServerLink(): Promise<void> {
    if (this.sharingBusy || !this.shareLink) {
      return;
    }
    this.sharingBusy = true;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.shareLink));
      this.shareStatus = '链接已复制';
    } catch (_) {
      this.shareStatus = '复制失败，请重试';
    } finally {
      this.sharingBusy = false;
    }
  }

  private async shareServerLink(): Promise<void> {
    if (this.sharingBusy || !this.shareLink) {
      return;
    }
    this.sharingBusy = true;
    try {
      const data = new systemShare.SharedData({
        utd: 'general.plain-text', content: this.shareLink, title: this.shareName
      });
      const controller = new systemShare.ShareController(data);
      await controller.show(this.context(), { previewMode: systemShare.SharePreviewMode.DEFAULT });
    } catch (_) {
      this.shareStatus = '未完成分享，可使用复制链接';
    } finally {
      this.sharingBusy = false;
    }
  }

  private async saveServer(): Promise<void> {
    if (!this.canManageServers()) {
      return;
    }
    if (this.serverInUse(this.editId)) {
      this.formError = '当前服务器正在使用，请断开 VPN 后再修改';
      return;
    }
    let newId = `${Date.now()}`;
    while (!this.editId && this.servers.some((item: ServerProfile) => item.id === newId)) {
      newId = `${Number(newId) + 1}`;
    }
    const server: ServerProfile = {
      id: this.editId || newId, name: this.editName.trim(), host: this.editHost.trim(),
      port: /^\d+$/.test(this.editPort) ? Number(this.editPort) : 0,
      method: CIPHERS[this.editMethod], password: this.editPassword
    };
    this.formError = validateServer(server);
    if (this.formError || this.saving) {
      return;
    }
    this.saving = true;
    const updated = this.editId ? this.servers.map((item: ServerProfile) => item.id === server.id ? server : item) :
      this.servers.concat([server]);
    const selection = this.selectedId || server.id;
    try {
      await ServerStore.save(this.context(), { servers: updated, selectedId: selection });
      this.servers = updated;
      this.selectedId = selection;
      this.closeEditor();
    } catch (_) {
      this.formError = '保存失败，请重试';
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(server: ServerProfile): void {
    if (!this.canManageServers() || this.serverInUse(server.id)) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除服务器', message: `删除“${server.name}”？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: this.colors().danger, action: () => { this.deleteServer(server); } }
    });
  }

  private async deleteServer(server: ServerProfile): Promise<void> {
    if (!this.canManageServers() || this.serverInUse(server.id)) {
      return;
    }
    this.busy = true;
    const updated = this.servers.filter((item: ServerProfile) => item.id !== server.id);
    const selection = this.selectedId === server.id ? (updated.length ? updated[0].id : '') : this.selectedId;
    try {
      await ServerStore.save(this.context(), { servers: updated, selectedId: selection });
      this.servers = updated;
      this.selectedId = selection;
    } catch (_) {
      this.error = '删除失败，请重试';
    } finally {
      this.busy = false;
    }
  }

  private async toggleVpn(): Promise<void> {
    if (this.busy || this.saving || this.updatingRules) {
      return;
    }
    const server = this.selected();
    const want: Want = { bundleName: BUNDLE_NAME, abilityName: VPN_ABILITY };
    this.busy = true;
    this.error = '';
    try {
      if (this.requested) {
        this.requestTime = Date.now();
        await vpnExtension.stopVpnExtensionAbility(want);
        this.requested = false;
        this.connected = false;
        this.status = '未连接';
      } else if (server) {
        if (this.routeMode === 'gfwlist' && !this.rulesReady) {
          this.error = '请先更新 GFWList';
          return;
        }
        const invalid = validateServer(server);
        if (invalid) {
          this.error = invalid;
          return;
        }
        this.requestTime = Date.now();
        if (readConnectionState(this.context()).phase === 'failed') {
          await vpnExtension.stopVpnExtensionAbility(want);
        }
        want.parameters = { ssUrl: serverUrl(server), serverId: server.id, routeMode: this.routeMode };
        await vpnExtension.startVpnExtensionAbility(want);
        this.requested = true;
        this.status = '正在连接';
      }
    } catch (_) {
      this.requestTime = 0;
      this.error = 'VPN 操作失败，请查看诊断日志';
    } finally {
      this.busy = false;
    }
  }

  private refreshLogs(): void {
    this.logText = ['vpn.log', 'ss.log', 't2s.log'].map((name: string) => readLog(this.context(), name)).join('\n\n');
  }

  @Builder
  private fieldLabel(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().secondaryText)
      .width('100%').margin({ top: 20, bottom: 8 })
  }

  @Builder
  private editor() {
    Column() {
      Text(this.editId ? '编辑服务器' : '添加服务器').fontSize(24).fontWeight(FontWeight.Bold)
        .fontColor(this.colors().text).width('100%').margin({ bottom: 12 })
      Scroll() {
        Column() {
          this.fieldLabel('名称')
          TextInput({ text: this.editName, placeholder: '例如：东京 · 主节点' }).maxLength(48)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .onChange((value: string) => { this.editName = value; }).height(48).borderRadius(6)
          this.fieldLabel('服务器地址')
          TextInput({ text: this.editHost, placeholder: '域名或 IP 地址' }).maxLength(253)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .onChange((value: string) => { this.editHost = value; }).height(48).borderRadius(6)
          this.fieldLabel('端口')
          TextInput({ text: this.editPort, placeholder: '8388' }).type(InputType.Number).maxLength(5)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .onChange((value: string) => { this.editPort = value; }).height(48).borderRadius(6)
          this.fieldLabel('加密方式')
          Select(CIPHERS.map((cipher: string): SelectOption => ({ value: cipher })))
            .selected(this.editMethod).value(CIPHERS[this.editMethod]).width('100%').height(48)
            .fontColor(this.colors().text).backgroundColor(this.colors().input)
            .optionFontColor(this.colors().text).optionBgColor(this.colors().input)
            .selectedOptionFontColor(this.colors().text).selectedOptionBgColor(this.colors().selectedInput)
            .onSelect((index: number) => { this.editMethod = index; })
          this.fieldLabel('密码')
          TextInput({ text: this.editPassword, placeholder: '服务器密码' }).type(InputType.Password)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .onChange((value: string) => { this.editPassword = value; }).height(48).borderRadius(6)
          if (this.formError) {
            Text(this.formError).fontSize(13).fontColor(this.colors().danger).width('100%').margin({ top: 16 })
          }
        }.width('100%').padding({ bottom: 24 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(6)
          .backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text)
          .enabled(!this.saving).onClick(() => this.closeEditor())
        Button(this.saving ? '保存中' : '保存服务器', { type: ButtonType.Normal }).layoutWeight(2).height(48)
          .borderRadius(6).backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
          .enabled(!this.saving).onClick(() => this.saveServer())
      }.padding({ top: 16 }).width('100%')
    }.width('100%').height('100%')
  }

  @Builder
  private importPage() {
    Column({ space: 16 }) {
      Row() {
        Button('取消').backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text)
          .enabled(!this.importingBusy).onClick(() => this.closeImport())
        Text('导入服务器').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
          .layoutWeight(1).textAlign(TextAlign.End)
      }.width('100%')
      Row({ space: 12 }) {
        Row() {
          PasteButton().height(44).width('100%')
            .enabled(!this.importingBusy && this.canManageServers())
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.importClipboard();
              } else {
                this.importError = '未获得剪贴板访问权限，可手动粘贴链接';
              }
            })
        }.layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.qrcode')).fontSize(20).fontColor([this.colors().onAccent])
            Text('扫码').fontSize(16).fontColor(this.colors().onAccent)
          }
        }.height(44).layoutWeight(1).borderRadius(6).backgroundColor(this.colors().accent)
          .enabled(!this.importingBusy && this.canManageServers()).onClick(() => this.scanServer())
      }.width('100%')
      TextArea({ text: this.importText, placeholder: 'ss://' }).maxLength(8192)
        .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
        .layoutWeight(1).width('100%').enabled(!this.importingBusy)
        .onChange((value: string) => { this.importText = value; this.importError = ''; })
      if (this.importError) {
        Text(this.importError).fontSize(13).fontColor(this.colors().danger).width('100%')
      }
      Button('读取配置', { type: ButtonType.Normal }).width('100%').height(48)
        .borderRadius(6).backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
        .enabled(!this.importingBusy && this.canManageServers() && this.importText.trim().length > 0)
        .onClick(() => this.importServer(this.importText))
    }.width('100%').height('100%')
  }

  @Builder
  private sharePage() {
    Column({ space: 16 }) {
      Row() {
        Button('返回').backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text)
          .onClick(() => this.closeShare())
        Text('分享服务器').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
          .layoutWeight(1).textAlign(TextAlign.End)
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Text(this.shareName).fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.shareLink.length <= 512) {
            Column() {
              QRCode(this.shareLink).width('100%').aspectRatio(1).color('#000000').backgroundColor('#FFFFFF')
            }.width('100%').constraintSize({ maxWidth: 288 }).padding(16).backgroundColor('#FFFFFF')
              .accessibilityText('服务器配置二维码，包含密码')
          } else {
            Text('链接过长，无法显示二维码').fontSize(14).fontColor(this.colors().danger)
          }
          Text('包含服务器密码，请仅分享给可信的人').fontSize(13).fontColor(this.colors().danger).width('100%')
        }.width('100%')
      }.layoutWeight(1).width('100%')
      if (this.shareStatus) {
        Text(this.shareStatus).fontSize(13).fontColor(this.colors().secondaryText).width('100%')
      }
      Row({ space: 12 }) {
        Button('复制链接', { type: ButtonType.Normal }).height(48).layoutWeight(1).borderRadius(6)
          .backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text).enabled(!this.sharingBusy)
          .onClick(() => this.copyServerLink())
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.share')).fontSize(20).fontColor([this.colors().onAccent])
            Text('分享').fontSize(16).fontColor(this.colors().onAccent)
          }
        }.height(48).layoutWeight(1).borderRadius(6).backgroundColor(this.colors().accent)
          .enabled(!this.sharingBusy).onClick(() => this.shareServerLink())
      }.width('100%')
    }.width('100%').height('100%')
  }

  @Builder
  private serverRow(server: ServerProfile) {
    Row({ space: 8 }) {
      Radio({ value: server.id, group: 'servers' }).checked(server.id === this.selectedId)
        .radioStyle({ checkedBackgroundColor: this.colors().accent }).enabled(!this.requested && !this.busy)
        .accessibilityText(`选择 ${server.name}`).onChange((checked: boolean) => { if (checked) { this.choose(server); } })
      Column({ space: 5 }) {
        Text(server.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(`${server.host}:${server.port}`).fontSize(13).fontColor(this.colors().secondaryText).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(server.method).fontSize(11).fontColor(this.colors().mutedText).width('100%')
        Text(this.usageText(server.id)).fontSize(12).fontColor(this.colors().secondaryText).width('100%')
        if (this.connected && server.id === this.trafficServerId) {
          Text(this.speedText()).fontSize(12).fontColor(this.colors().accent).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => this.choose(server))
      Column() {
        Row({ space: 4 }) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.share')).fontSize(20).fontColor([this.colors().secondaryText])
          }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
            .accessibilityText(`分享 ${server.name}`).bindTips('分享服务器').enabled(!this.busy)
            .onClick(() => this.openShare(server))
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus_square_on_square')).fontSize(20).fontColor([this.colors().secondaryText])
          }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
            .accessibilityText(`复制 ${server.name}`).bindTips('复制服务器配置')
            .enabled(this.canManageServers())
            .onClick(() => this.duplicateServer(server))
        }
        Row({ space: 4 }) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(20).fontColor([this.colors().secondaryText])
          }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
            .accessibilityText(`编辑 ${server.name}`).enabled(this.canManageServers() && !this.serverInUse(server.id))
            .onClick(() => this.openEditor(server))
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(20).fontColor([this.colors().secondaryText])
          }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
            .accessibilityText(`删除 ${server.name}`).enabled(this.canManageServers() && !this.serverInUse(server.id))
            .onClick(() => this.confirmDelete(server))
        }
      }.width(84).height(88)
    }.width('100%').padding({ top: 18, bottom: 18, left: 6, right: 6 })
      .backgroundColor(server.id === this.selectedId ? this.colors().selectedRow : Color.Transparent)
      .border({ width: { bottom: 1 }, color: this.colors().border })
  }

  build() {
    Column() {
      if (this.importing) {
        this.importPage()
      } else if (this.shareLink) {
        this.sharePage()
      } else if (this.editing) {
        this.editor()
      } else if (this.showLogs) {
        Row() {
          Button('返回').onClick(() => { this.showLogs = false; }).backgroundColor(this.colors().accent)
            .fontColor(this.colors().onAccent)
          Text('诊断日志').fontSize(20).fontColor(this.colors().text).layoutWeight(1).textAlign(TextAlign.Center)
          Button('刷新').onClick(() => this.refreshLogs()).backgroundColor(this.colors().accent)
            .fontColor(this.colors().onAccent)
        }.width('100%')
        Scroll() {
          Text(this.logText).fontSize(12).fontColor(this.colors().secondaryText).width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }.layoutWeight(1).margin({ top: 20 }).align(Alignment.TopStart)
      } else {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(28).fontColor([this.colors().accent])
          Text('Shadowsocks').fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
          Button(this.themeMode === 'dark' ? '浅色' : '深色', { type: ButtonType.Normal })
            .height(40).borderRadius(6).backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text)
            .accessibilityText(this.themeMode === 'dark' ? '切换到浅色主题' : '切换到深色主题')
            .onClick(() => this.toggleTheme())
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.doc_plaintext_fill_1')).fontSize(22).fontColor([this.colors().secondaryText])
          }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('诊断日志')
            .onClick(() => { this.refreshLogs(); this.showLogs = true; })
        }.width('100%')
        Row({ space: 8 }) {
          Row().width(8).height(8).borderRadius(4)
            .backgroundColor(this.connected ? this.colors().accent : this.colors().inactive)
          Text(this.status).fontSize(14)
            .fontColor(this.connected ? this.colors().accent : this.colors().secondaryText)
          Blank()
          Text('VPN').fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.colors().mutedText)
        }.width('100%').margin({ top: 24, bottom: 24 })
        if (this.trafficError) {
          Text(this.trafficError).fontSize(12).fontColor(this.colors().danger).width('100%').margin({ bottom: 12 })
        }
        Divider().color(this.colors().border)
        Row({ space: 8 }) {
          Text('代理模式').fontSize(14).fontColor(this.colors().secondaryText)
          Select([{ value: '全局' }, { value: 'GFWList' }])
            .selected(this.routeMode === 'gfwlist' ? 1 : 0)
            .value(this.routeMode === 'gfwlist' ? 'GFWList' : '全局')
            .height(44).layoutWeight(1)
            .fontColor(this.colors().text).backgroundColor(this.colors().input)
            .optionFontColor(this.colors().text).optionBgColor(this.colors().input)
            .selectedOptionFontColor(this.colors().text).selectedOptionBgColor(this.colors().selectedInput)
            .accessibilityText('代理模式')
            .enabled(this.ready && !this.busy && !this.requested && !this.updatingRules)
            .onSelect((index: number) => { this.changeRoute(index === 1 ? 'gfwlist' : 'global'); })
        }.width('100%').margin({ top: 12 })
        if (this.requested) {
          Text('断开后可切换').fontSize(12).fontColor(this.colors().secondaryText).width('100%').margin({ top: 4 })
        }
        if (this.routeMode === 'gfwlist') {
          Row({ space: 8 }) {
            Text(this.updatingRules ? '正在更新 GFWList' : this.rulesStatus)
              .fontSize(12).fontColor(this.colors().secondaryText).layoutWeight(1).maxLines(2)
            Button({ type: ButtonType.Normal }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(22).fontColor([this.colors().accent])
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .accessibilityText('更新 GFWList').bindTips('更新 GFWList')
              .enabled(this.ready && !this.busy && !this.updatingRules).onClick(() => this.updateRules())
          }.width('100%')
        }
        Row() {
          Text('服务器').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
          Text(`${this.servers.length}`).fontSize(13).fontColor(this.colors().mutedText).margin({ left: 8 })
          Blank()
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_down_circle')).fontSize(23).fontColor([this.colors().accent])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText('导入服务器').bindTips('导入服务器')
            .enabled(this.canManageServers()).onClick(() => this.openImport())
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(23).fontColor([this.colors().accent])
          }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('添加服务器')
            .enabled(this.canManageServers()).onClick(() => this.openEditor())
        }.width('100%').margin({ top: 16, bottom: 8 })
        if (!this.servers.length) {
          Column({ space: 16 }) {
            SymbolGlyph($r('sys.symbol.network_acceleration')).fontSize(44).fontColor([this.colors().inactive])
            Text(this.ready ? '暂无服务器' : '正在读取配置').fontSize(16).fontColor(this.colors().secondaryText)
            if (this.ready) {
              Button('添加服务器').backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
                .onClick(() => this.openEditor())
            }
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.servers, (server: ServerProfile) => {
              ListItem() { this.serverRow(server) }
            }, (server: ServerProfile) => server.id)
          }.width('100%').layoutWeight(1)
        }
        if (this.error) {
          Text(this.error).fontSize(13).fontColor(this.colors().danger).width('100%').maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 12 })
        }
        Column({ space: 12 }) {
          Text(this.selected()?.name ?? '未选择服务器').fontSize(14).fontColor(this.colors().secondaryText)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Button(this.requested ? (this.connected ? '断开连接' : '取消连接') : '连接', { type: ButtonType.Normal })
            .width('100%').height(52).borderRadius(6).fontSize(17).fontWeight(FontWeight.Medium)
            .backgroundColor(this.requested ? this.colors().disconnect : this.colors().accent)
            .fontColor(this.colors().onAccent)
            .enabled(this.ready && !this.busy && !this.updatingRules && (this.requested || this.selected() !== undefined))
            .onClick(() => this.toggleVpn())
        }.width('100%').padding({ top: 20 }).margin({ top: 12 })
      }
    }.width('100%').height('100%').padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(this.colors().background)
  }
}