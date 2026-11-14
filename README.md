# shadowsocks_ohos

HarmonyOS VPN 原型：应用内启动 `go-shadowsocks2`（SOCKS5 `:1080`），再用 `go-tun2socks` 把系统 VPN TUN fd 转到该 SOCKS5。

不在应用里实现 Shadowsocks 加解密。`-redir :1082` 依赖 Linux netfilter，鸿蒙 VPN 给的是 TUN fd，所以用 tun2socks。

## 数据路径

```
App 流量 → HarmonyOS VPN TUN fd
        → libssgo.so 内的 go-tun2socks
        → go-shadowsocks2 SOCKS5 :1080
        → ss:// 远程服务器
```

`go-shadowsocks2` 出站和 tun2socks 连 SOCKS 的套接字会走 `protectProcessNet`，避免套娃进 VPN。

## 构建 Go 动态库

当前通过 NAPI 包装层 `libssengine.so` 在进程内加载 `libssgo.so`，不再启动独立 Go 可执行文件。

需要使用HarmonyOS的go编译器来编译，否则`https://github.com/sysit/ohos-go.git`

标准 Linux Go 的 c-shared 仍然不兼容这里的动态 TLS。需要为ohos定制的go编译器。下载ohos-go，并解压到tmp目录。

```bash
curl -fL --connect-timeout 20 --max-time 180 https://codeload.github.com/sysit/ohos-go/tar.gz/2417e0834a96530125db3d295884c1ddf86777d7 -o /tmp/shadowsocks-ohos-go-2417e08.tar.gz && mkdir -p /tmp/shadowsocks-ohos-go-2417e08 && tar -xzf /tmp/shadowsocks-ohos-go-2417e08.tar.gz --strip-components=1 -C /tmp/shadowsocks-ohos-go-2417e08 && rg -n 'c-shared|TLS|make.bash|GOOS|CGO|CC=' /tmp/shadowsocks-ohos-go-2417e08/docs -g '*.md' | head -85
```

- 使用支持 `openharmony/arm64` 的 Go 工具链；普通 `GOOS=linux` 的 Go 动态库存在 OHOS TLS 兼容问题。
- 主机回归测试使用 PATH 中的标准 `go`（1.24.1 或更高版本），可通过 `HOST_GO` 指定。
- 安装 DevEco Studio 的 ARM64 native SDK，可通过 `OHOS_NDK` 覆盖默认 SDK 路径。
- 当前 `native/ssengine/go.mod` 使用本地 `replace`：`go-shadowsocks2` 需要包含新增的 xchacha 实现，`go-tun2socks` 需要包含 `StartFromIO` 适配。更换电脑时须更新这两个路径。

在项目根目录执行（`OHOS_GO` 改成实际工具链位置）：

```sh
OHOS_GO=/tmp/shadowsocks-ohos-go-2417e08/bin/go ./native/ssengine/build.sh
```

脚本先运行 xchacha URL/加密兼容测试及 DNS 回归测试，再生成：

- `entry/libs/arm64-v8a/libssgo.so`：HAP 打包使用的 Go 动态库。
- `entry/libs/arm64-v8a/libssgo.h`：Go 导出的 C 接口。

不再保留 rawfile 中的独立 Go 可执行文件或 `cpp/third_party` 中的旧库副本；运行时只使用 HAP libs 中的动态库。

不要将 Go 输出命名为 `libssengine.so`，该文件由 CMake 构建的 NAPI 包装层提供。
重新构建动态库后，还需在 DevEco Studio 构建并安装 HAP，手机上才会使用新引擎。

## 加密方式

添加和编辑服务器支持 `chacha20-ietf-poly1305`、`aes-128-gcm`、`aes-256-gcm` 和 `xchacha20-ietf-poly1305`。
xchacha 对应本地 Go 库中的 `AEAD_XCHACHA20_POLY1305`；服务端须支持同一算法，密码和加密方式必须匹配。

## 分享和导入服务器

- 点击服务器行的分享图标，可展示二维码、复制 `ss://` 链接或打开系统分享面板。
- 服务器列表标题栏仅保留「+」入口，菜单提供「手工添加服务器」「扫描二维码」「ss:// 链接」；链接页支持剪贴板粘贴和手动输入，扫码界面也支持从相册选择二维码。空列表的「添加服务器」使用相同菜单。
- 菜单中的「扫描二维码」直接打开系统扫码，不先进入导入页；取消回到服务器列表，错误也在列表页显示，成功后打开配置表单确认保存。
- 导入后先打开新增服务器表单，检查配置后点击「保存服务器」。连接 VPN 期间仍可手动新增、粘贴/URL/扫码导入和复制服务器；保存不会自动切换节点或覆盖已有配置。
- VPN 正在连接或已连接时，只禁止编辑、删除当前节点及切换节点、代理模式；其他服务器可正常编辑、删除。复制当前节点也只创建副本，不影响当前连接。
- 导出使用 SIP002 格式：`ss://BASE64URL(method:password)@host:port#备注`。备注进行百分号编码，IPv6 使用方括号。兼容 SIP002 Base64/明文认证信息和旧版整串 Base64 链接。
- 每次导入一条链接；仅支持应用已有的四种加密方式，不支持 SIP003 插件或其他查询扩展参数，遇到这些链接会明确报错。
- 链接和二维码包含可还原的密码，Base64 **不是加密**。只分享给可信的人；本功能不记录分享内容、不自动读取剪贴板、不使用在线二维码服务。剪贴板读取由用户点击系统粘贴安全控件后临时授权，系统扫码界面无需应用额外申请相机权限。
- HarmonyOS 二维码控件最多支持 512 字符，超过时不生成截断二维码，但仍可复制或系统分享链接。导入和导出的链接上限为 8192 字符。
- 回归测试：`node --test entry/src/test/ServerLink.host.cjs`，可通过 `TYPESCRIPT_PATH` 指定 TypeScript 安装目录。
- 连接状态下的配置管理测试：`node --test entry/src/test/ServerManagement.host.cjs`。

## 主题

- 主界面标题栏可在浅色和深色主题之间切换，选择会保存在本机并在下次启动时恢复。
- 主题会同步到系统控件；分享二维码始终使用黑白高对比配色，确保扫码可靠性。

## 流量和速度

- 每个服务器显示累计上传、下载用量；当前已连接的服务器同时显示上传、下载速度，每秒刷新。速度按实际采样间隔计算，空闲时归零，断开后隐藏。
- 用量按服务器配置 ID 保存在本机，跨连接和应用重启累计。编辑同一配置保留累计值；复制、重新导入会生成新 ID，从零开始。不包含安装此功能前的历史流量。
- Go 在 Shadowsocks 加密层下统计 TCP/UDP 实际读写字节，包含 SS 协议和加密开销，不包含 IP/TCP/UDP 包头及 TCP 重传；GFWList 直连流量和连接前的诊断探测不计入，因此不是运营商计费用量。
- VPN 扩展独立于界面采样并原子保存累计值，关闭主界面不会停止统计；正常断开时补采样。进程被强制终止时，最后一次成功保存之后的流量可能丢失（正常采样间隔约一秒）。统计读取或保存失败会显示错误，不覆盖已有累计值。
- 使用二进制单位 B、KiB、MiB、GiB，速度单位为每秒字节。更新后必须重建并打包 `libssgo.so`，旧动态库不支持统计接口。
- 回归测试：`node --test entry/src/test/TrafficStore.host.cjs entry/src/test/ServerManagement.host.cjs`；native 计数、并发和直连排除测试已加入 `native/ssengine/build.sh`。

## GFWList 分流

- 主界面选择「全局」或「GFWList」，路由模式会保存；连接期间需先断开再切换。
- 首次使用 GFWList 时点击刷新图标下载规则。依次尝试 gcore、testingcf、fastly jsDelivr HTTPS 镜像和 GitHub 官方原始地址，来源来自 GFWList 仓库 README。
- 更新有超时和 4 MiB 大小限制，先验证并规范化域名，再原子替换规则文件。更新失败保留旧列表；连接期间更新在下次连接生效。未下载有效列表时不能启动 GFWList 模式。
- GFWList 模式以直连为默认，支持域名及子域、`||domain`、`.domain`、`*.domain` 和可提取主机名的 URL 规则；`@@` 域名例外优先直连。URL 代理规则按整个域名处理，不按路径匹配。
- 正则、复杂通配符、带选项的规则、IP 规则及仅针对 URL 路径的例外不支持，下载后显示跳过数量；不是 Android 完整 ACL 或自定义 ACL 编辑器。
- 系统 VPN 仍接管 IPv4 流量；Go 引擎在 SOCKS TCP/UDP 层决定直连或 SS。DNS 使用 `golang.org/x/net/dns/dnsmessage` 解析，命中域名返回 `198.18.0.0/15` 虚拟 IP，转发时恢复原域名交由 SS 服务端解析。映射持久化，重连不会将缓存的虚拟 IP 指向其他域名。
- 未命中的域名使用 `223.5.5.5` / `119.29.29.29` 直连 DNS。命中域名的 AAAA、HTTPS/SVCB 查询返回空结果，避免真实 IPv6 或地址提示绕过 IPv4 分流。其他命中域名 DNS 查询经现有 SS TCP DNS 隧道。
- 分流依赖应用使用 VPN DNS。自带 DoH/DoT、连接前缓存的真实 IP、直接访问 IP 无法可靠还原域名，默认直连。无法还原域名的公网 IP 若 TCP 建连超过 1.5 秒，则经 SS 重试，避免缓存的 Google IP 一直直连超时；内网地址、明确的直连域名、非超时错误不触发此兜底。兜底只针对 TCP 建连，不处理 UDP 或已连接后的停顿，也不保证修复错误 DNS 地址。首次切换建议关闭浏览器安全 DNS 并重启浏览器；当前不提供完整 IPv6 代理。
- 列表在连接配置时解析一次并保存在内存，匹配使用域名后缀哈希查找，不会每次访问重新下载或扫描列表。已有虚拟 IP 的查询不会等待新映射落盘。
- TUN 的 UDP DNS 保留已验证的本地 DNS 转发入口，上游代理 DNS 使用 SS TCP 隧道。强制改走 SOCKS UDP 的版本出现全局模式访问回归，已恢复原入口；同一 UDP 会话多次 DNS 查询的优化仍需端到端验证。
- 诊断日志中 `route TCP proxy/direct`、`route UDP proxy=true/false` 可核对实际路由。分流不是隐私防泄漏模式。

更新 native 代码后，先运行 `native/ssengine/build.sh`，再构建 HAP。该脚本会运行规则、TCP/UDP 路由、DNS、映射持久化及现有加密回归测试。
下载器主机测试：`node --test entry/src/test/RoutingStore.host.cjs`（默认使用 DevEco 的 TypeScript，可用 `TYPESCRIPT_PATH` 覆盖）。
设置 `GFWLIST_TEST_FILE` 为本地 GFWList 文件路径可额外运行真实列表测试。

## 试用

1. DevEco Studio 打开本工程，用 HarmonyOS 手机签名安装。
2. 打开应用，确认 SS URL（已预填你验证过的节点）。
3. 点「连接 VPN」，允许系统 VPN 授权。
4. 状态栏出现钥匙后，用浏览器访问网站。
5. 日志：`filesDir/ss.log`、`filesDir/t2s.log`。

需要 `ohos.permission.INTERNET`。首次连接会弹 VPN 授权。
