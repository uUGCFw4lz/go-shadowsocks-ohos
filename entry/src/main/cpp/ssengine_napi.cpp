#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <vector>

#include "hilog/log.h"
#include "napi/native_api.h"

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "ssengine"

typedef int (*FnSsSetLogPath)(char *path);
typedef int (*FnSsStartClient)(char *ssURL, char *socksAddr, char *udpTun, char *tcpTun, int verbose,
    char *errBuf, int errBufLen);
typedef int (*FnSsStartTun2Socks)(int tunFd, char *socksAddr, int mtu, char *dns, char *errBuf, int errBufLen);

static void *g_engine = nullptr;
static FnSsSetLogPath g_setLog = nullptr;
static FnSsStartClient g_startClient = nullptr;
static FnSsStartTun2Socks g_startTun = nullptr;
static std::string g_engineStatus = "not loaded";
static std::string g_enginePath;

static std::vector<char> MutableCString(const std::string &s)
{
    std::vector<char> out(s.begin(), s.end());
    out.push_back('\0');
    return out;
}

static std::string GetString(napi_env env, napi_value value)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::vector<char> buf(len + 1, '\0');
    napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len);
    return std::string(buf.data(), len);
}

static napi_value ThrowError(napi_env env, const std::string &msg)
{
    napi_throw_error(env, nullptr, msg.c_str());
    return nullptr;
}

static std::string DirName(const char *path)
{
    std::string s(path ? path : "");
    auto pos = s.find_last_of('/');
    if (pos == std::string::npos) {
        return ".";
    }
    return s.substr(0, pos);
}

static bool TryDlopen(const std::string &path)
{
    dlerror();
    void *h = dlopen(path.c_str(), RTLD_NOW);
    if (h == nullptr) {
        const char *err = dlerror();
        std::string msg = std::string("dlopen fail ") + path + ": " + (err ? err : "unknown");
        if (g_engineStatus == "not loaded") {
            g_engineStatus = msg;
        } else {
            g_engineStatus += " | " + msg;
        }
        OH_LOG_WARN(LOG_APP, "%{public}s", msg.c_str());
        return false;
    }
    auto setLog = reinterpret_cast<FnSsSetLogPath>(dlsym(h, "SsSetLogPath"));
    auto startClient = reinterpret_cast<FnSsStartClient>(dlsym(h, "SsStartClient"));
    auto startTun = reinterpret_cast<FnSsStartTun2Socks>(dlsym(h, "SsStartTun2Socks"));
    if (startClient == nullptr || startTun == nullptr) {
        g_engineStatus = std::string("dlsym missing SsStart* from ") + path;
        OH_LOG_ERROR(LOG_APP, "%{public}s", g_engineStatus.c_str());
        return false;
    }
    g_engine = h;
    g_setLog = setLog;
    g_startClient = startClient;
    g_startTun = startTun;
    g_engineStatus = std::string("dlopen ok ") + path;
    OH_LOG_INFO(LOG_APP, "%{public}s", g_engineStatus.c_str());
    return true;
}

static bool LoadEngine()
{
    if (g_startClient != nullptr && g_startTun != nullptr) {
        return true;
    }
    std::vector<std::string> cands;
    if (!g_enginePath.empty()) {
        cands.push_back(g_enginePath);
    }
    cands.emplace_back("libssgo.so");

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(reinterpret_cast<void *>(LoadEngine), &info) && info.dli_fname != nullptr) {
        cands.push_back(DirName(info.dli_fname) + "/libssgo.so");
        if (g_engineStatus == "not loaded") {
            g_engineStatus = std::string("libssengine=") + info.dli_fname;
        }
    }

    for (const auto &p : cands) {
        if (TryDlopen(p)) {
            return true;
        }
    }
    return false;
}

static napi_value NapiSetEnginePath(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return ThrowError(env, "setEnginePath(path) required");
    }
    g_enginePath = GetString(env, argv[0]);
    g_engineStatus = std::string("path set ") + g_enginePath;
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value NapiStartSsClient(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value argv[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        return ThrowError(env, "startSsClient(ssUrl, socksAddr, udpTun, tcpTun, logPath) required");
    }
    std::string ssUrl = GetString(env, argv[0]);
    std::string socksAddr = GetString(env, argv[1]);
    std::string udpTun = GetString(env, argv[2]);
    std::string tcpTun = GetString(env, argv[3]);
    std::string logPath;
    if (argc >= 5) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[4], &t);
        if (t == napi_string) {
            logPath = GetString(env, argv[4]);
        }
    }
    if (!LoadEngine()) {
        return ThrowError(env, std::string("load libssgo.so failed: ") + g_engineStatus);
    }
    if (!logPath.empty() && g_setLog != nullptr) {
        auto p = MutableCString(logPath);
        g_setLog(p.data());
    }
    auto ss = MutableCString(ssUrl);
    auto socks = MutableCString(socksAddr);
    auto udp = MutableCString(udpTun);
    auto tcp = MutableCString(tcpTun);
    char errBuf[512] = {0};
    if (argc >= 6) {
        using ConfigureRouting = int (*)(char *, char *, int);
        auto configure = reinterpret_cast<ConfigureRouting>(dlsym(g_engine, "SsConfigureRouting"));
        if (configure == nullptr) {
            return ThrowError(env, "SsConfigureRouting missing; rebuild libssgo.so");
        }
        auto routePath = MutableCString(GetString(env, argv[5]));
        if (configure(routePath.data(), errBuf, sizeof(errBuf)) != 0) {
            return ThrowError(env, std::string("routing configuration failed: ") + errBuf);
        }
    }
    int rc = g_startClient(ss.data(), socks.data(), udp.data(), tcp.data(), 1, errBuf, sizeof(errBuf));
    if (rc != 0) {
        std::string msg = errBuf[0] ? errBuf : "SsStartClient failed";
        return ThrowError(env, msg);
    }
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value NapiStartTun2Socks(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        return ThrowError(env, "startTun2Socks(tunFd, socksAddr, mtu, dns, logPath) required");
    }
    int32_t tunFd = -1;
    napi_get_value_int32(env, argv[0], &tunFd);
    std::string socksAddr = GetString(env, argv[1]);
    int32_t mtu = 1400;
    napi_get_value_int32(env, argv[2], &mtu);
    std::string dns = GetString(env, argv[3]);
    std::string logPath;
    if (argc >= 5) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[4], &t);
        if (t == napi_string) {
            logPath = GetString(env, argv[4]);
        }
    }
    if (tunFd < 0) {
        return ThrowError(env, "invalid tun fd");
    }
    if (!LoadEngine()) {
        return ThrowError(env, std::string("load libssgo.so failed: ") + g_engineStatus);
    }
    int fdFlags = fcntl(tunFd, F_GETFD);
    if (fdFlags >= 0) {
        fcntl(tunFd, F_SETFD, fdFlags & ~FD_CLOEXEC);
    }
    int fl = fcntl(tunFd, F_GETFL);
    if (fl >= 0) {
        fcntl(tunFd, F_SETFL, fl & ~O_NONBLOCK);
    }
    if (!logPath.empty() && g_setLog != nullptr) {
        auto p = MutableCString(logPath);
        g_setLog(p.data());
    }
    auto socks = MutableCString(socksAddr);
    auto dnsBuf = MutableCString(dns);
    char errBuf[512] = {0};
    int rc = g_startTun(tunFd, socks.data(), mtu, dnsBuf.data(), errBuf, sizeof(errBuf));
    if (rc != 0) {
        std::string msg = errBuf[0] ? errBuf : "SsStartTun2Socks failed";
        return ThrowError(env, msg);
    }
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value NapiEngineStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    LoadEngine();
    napi_value result;
    napi_create_string_utf8(env, g_engineStatus.c_str(), g_engineStatus.size(), &result);
    return result;
}

static napi_value NapiGetTrafficStats(napi_env env, napi_callback_info info)
{
    (void)info;
    if (!LoadEngine()) {
        return ThrowError(env, std::string("load libssgo.so failed: ") + g_engineStatus);
    }
    using GetTrafficStats = void (*)(unsigned long long *, unsigned long long *);
    auto getStats = reinterpret_cast<GetTrafficStats>(dlsym(g_engine, "SsGetTrafficStats"));
    if (getStats == nullptr) {
        return ThrowError(env, "SsGetTrafficStats missing; rebuild libssgo.so");
    }
    unsigned long long uploaded = 0;
    unsigned long long downloaded = 0;
    getStats(&uploaded, &downloaded);
    napi_value result, up, down;
    napi_create_object(env, &result);
    napi_create_double(env, static_cast<double>(uploaded), &up);
    napi_create_double(env, static_cast<double>(downloaded), &down);
    napi_set_named_property(env, result, "uploadedBytes", up);
    napi_set_named_property(env, result, "downloadedBytes", down);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_attributes attr = static_cast<napi_property_attributes>(
        napi_writable | napi_enumerable | napi_configurable);
    napi_property_descriptor desc[] = {
        {"setEnginePath", nullptr, NapiSetEnginePath, nullptr, nullptr, nullptr, attr, nullptr},
        {"startSsClient", nullptr, NapiStartSsClient, nullptr, nullptr, nullptr, attr, nullptr},
        {"startTun2Socks", nullptr, NapiStartTun2Socks, nullptr, nullptr, nullptr, attr, nullptr},
        {"engineStatus", nullptr, NapiEngineStatus, nullptr, nullptr, nullptr, attr, nullptr},
        {"getTrafficStats", nullptr, NapiGetTrafficStats, nullptr, nullptr, nullptr, attr, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ssengine",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSsengineModule()
{
    napi_module_register(&g_module);
}
