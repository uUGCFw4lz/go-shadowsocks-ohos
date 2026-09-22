# shadowsocks_ohos 原型

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

标准 Linux Go 的 c-shared 仍然不兼容这里的动态 TLS。需要为ohos定制的go编译器。

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

## 试用

1. DevEco Studio 打开本工程，用 HarmonyOS 手机签名安装。
2. 打开应用，确认 SS URL（已预填你验证过的节点）。
3. 点「连接 VPN」，允许系统 VPN 授权。
4. 状态栏出现钥匙后，用浏览器访问网站。
5. 日志：`filesDir/ss.log`、`filesDir/t2s.log`。

需要 `ohos.permission.INTERNET`。首次连接会弹 VPN 授权。
