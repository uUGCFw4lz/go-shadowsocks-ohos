#include <arpa/inet.h>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include "hilog/log.h"
#include "napi/native_api.h"

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "sscore"

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
    cands.emplace_back("libssengine.so");

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(reinterpret_cast<void *>(LoadEngine), &info) && info.dli_fname != nullptr) {
        cands.push_back(DirName(info.dli_fname) + "/libssengine.so");
        g_engineStatus = std::string("libentry=") + info.dli_fname;
    }

    cands.emplace_back("/data/storage/el1/bundle/libs/arm64/libssengine.so");
    cands.emplace_back("/data/storage/el1/bundle/libs/arm64-v8a/libssengine.so");
    cands.emplace_back("/data/storage/el1/bundle/entry/libs/arm64/libssengine.so");
    cands.emplace_back("/data/storage/el1/bundle/entry/libs/arm64-v8a/libssengine.so");

    for (const auto &p : cands) {
        if (TryDlopen(p)) {
            return true;
        }
    }
    return false;
}

extern char **environ;

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
    OH_LOG_INFO(LOG_APP, "setEnginePath %{public}s", g_enginePath.c_str());
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value NapiSpawn(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        return ThrowError(env, "spawn(path, args, inheritFds, logPath) required");
    }

    std::string path = GetString(env, argv[0]);
    uint32_t argLen = 0;
    napi_get_array_length(env, argv[1], &argLen);

    std::vector<std::string> argStore;
    argStore.reserve(argLen + 1);
    argStore.push_back(path);
    for (uint32_t i = 0; i < argLen; i++) {
        napi_value item;
        napi_get_element(env, argv[1], i, &item);
        argStore.push_back(GetString(env, item));
    }

    std::vector<char *> argvp;
    for (auto &s : argStore) {
        argvp.push_back(const_cast<char *>(s.c_str()));
    }
    argvp.push_back(nullptr);

    if (argc >= 3) {
        uint32_t fdLen = 0;
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[2], &t);
        if (t == napi_object) {
            napi_get_array_length(env, argv[2], &fdLen);
            for (uint32_t i = 0; i < fdLen; i++) {
                napi_value item;
                napi_get_element(env, argv[2], i, &item);
                int32_t fd = -1;
                napi_get_value_int32(env, item, &fd);
                if (fd >= 0) {
                    int flags = fcntl(fd, F_GETFD);
                    if (flags >= 0) {
                        fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC);
                    }
                }
            }
        }
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    std::string logPath;
    if (argc >= 4) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[3], &t);
        if (t == napi_string) {
            logPath = GetString(env, argv[3]);
        }
    }
    if (!logPath.empty()) {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath.c_str(),
            O_WRONLY | O_CREAT | O_APPEND, 0644);
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    }

    // Keep inherited fds at their original numbers and also dup TUN to 3,
    // which is the first unused fd after stdin/out/err in the child.
    if (argc >= 3) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[2], &t);
        if (t == napi_object) {
            uint32_t fdLen = 0;
            napi_get_array_length(env, argv[2], &fdLen);
            if (fdLen > 0) {
                napi_value item;
                napi_get_element(env, argv[2], 0, &item);
                int32_t fd = -1;
                napi_get_value_int32(env, item, &fd);
                if (fd >= 0) {
                    int flags = fcntl(fd, F_GETFL);
                    if (flags >= 0) {
                        fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
                    }
                    posix_spawn_file_actions_adddup2(&actions, fd, 3);
                }
            }
        }
    }

    pid_t pid = -1;
    int ret = posix_spawn(&pid, path.c_str(), &actions, nullptr, argvp.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "posix_spawn %{public}s failed: %{public}s", path.c_str(), strerror(ret));
        return ThrowError(env, std::string("posix_spawn failed: ") + strerror(ret));
    }
    OH_LOG_INFO(LOG_APP, "spawned %{public}s pid=%{public}d", path.c_str(), pid);

    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(pid), &result);
    return result;
}

static napi_value NapiKillPid(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t pid = 0;
    napi_get_value_int32(env, argv[0], &pid);
    int32_t sig = SIGTERM;
    if (argc >= 2) {
        napi_get_value_int32(env, argv[1], &sig);
    }
    if (pid > 1) {
        kill(static_cast<pid_t>(pid), sig);
        if (sig == SIGTERM) {
            usleep(100 * 1000);
            kill(static_cast<pid_t>(pid), SIGKILL);
        }
        int status = 0;
        waitpid(static_cast<pid_t>(pid), &status, WNOHANG);
    }
    return nullptr;
}

static napi_value NapiIsAlive(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t pid = 0;
    napi_get_value_int32(env, argv[0], &pid);
    bool alive = pid > 1 && kill(static_cast<pid_t>(pid), 0) == 0;
    napi_value result;
    napi_get_boolean(env, alive, &result);
    return result;
}

static napi_value NapiChmod(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string path = GetString(env, argv[0]);
    int32_t mode = 0755;
    napi_get_value_int32(env, argv[1], &mode);
    if (chmod(path.c_str(), static_cast<mode_t>(mode)) != 0) {
        OH_LOG_WARN(LOG_APP, "chmod %{public}s failed: %{public}s", path.c_str(), strerror(errno));
    }
    return nullptr;
}

static napi_value NapiWaitPort(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string host = GetString(env, argv[0]);
    int32_t port = 0;
    int32_t timeoutMs = 5000;
    napi_get_value_int32(env, argv[1], &port);
    napi_get_value_int32(env, argv[2], &timeoutMs);

    bool ok = false;
    const int step = 100;
    for (int elapsed = 0; elapsed < timeoutMs; elapsed += step) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            break;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(port));
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
        int rc = connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
        if (rc == 0) {
            ok = true;
            close(fd);
            break;
        }
        if (errno == EINPROGRESS) {
            pollfd pfd {fd, POLLOUT, 0};
            int pr = poll(&pfd, 1, step);
            if (pr > 0 && (pfd.revents & POLLOUT)) {
                int err = 0;
                socklen_t len = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                if (err == 0) {
                    ok = true;
                    close(fd);
                    break;
                }
            }
        }
        close(fd);
        usleep(step * 1000);
    }

    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static bool WaitReadable(int fd, int timeoutMs)
{
    pollfd pfd {fd, POLLIN, 0};
    int pr = poll(&pfd, 1, timeoutMs);
    return pr > 0 && (pfd.revents & POLLIN);
}

static bool WaitWritable(int fd, int timeoutMs)
{
    pollfd pfd {fd, POLLOUT, 0};
    int pr = poll(&pfd, 1, timeoutMs);
    return pr > 0 && (pfd.revents & POLLOUT);
}

static bool WriteAll(int fd, const uint8_t *data, size_t n, int timeoutMs)
{
    size_t off = 0;
    while (off < n) {
        if (!WaitWritable(fd, timeoutMs)) {
            return false;
        }
        ssize_t w = send(fd, data + off, n - off, 0);
        if (w <= 0) {
            return false;
        }
        off += static_cast<size_t>(w);
    }
    return true;
}

static ssize_t ReadSome(int fd, uint8_t *buf, size_t n, int timeoutMs)
{
    if (!WaitReadable(fd, timeoutMs)) {
        return -1;
    }
    return recv(fd, buf, n, 0);
}

static napi_value NapiSocksHttpGet(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string socksHost = GetString(env, argv[0]);
    int32_t socksPort = 0;
    std::string destHost = GetString(env, argv[2]);
    int32_t destPort = 80;
    int32_t timeoutMs = 8000;
    napi_get_value_int32(env, argv[1], &socksPort);
    napi_get_value_int32(env, argv[3], &destPort);
    napi_get_value_int32(env, argv[4], &timeoutMs);

    std::string msg = "fail";
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        msg = std::string("socket: ") + strerror(errno);
    } else {
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(socksPort));
        inet_pton(AF_INET, socksHost.c_str(), &addr.sin_addr);
        int rc = connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
        if (rc != 0 && errno != EINPROGRESS) {
            msg = std::string("connect socks: ") + strerror(errno);
        } else if (!WaitWritable(fd, timeoutMs)) {
            msg = "connect socks timeout";
        } else {
            int soerr = 0;
            socklen_t len = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
            if (soerr != 0) {
                msg = std::string("connect socks: ") + strerror(soerr);
            } else {
                const uint8_t hello[] = {0x05, 0x01, 0x00};
                uint8_t buf[512] {};
                if (!WriteAll(fd, hello, sizeof(hello), timeoutMs) || ReadSome(fd, buf, 2, timeoutMs) < 2) {
                    msg = "socks hello failed";
                } else if (buf[0] != 0x05 || buf[1] != 0x00) {
                    msg = "socks auth rejected";
                } else {
                    std::vector<uint8_t> req;
                    req.push_back(0x05);
                    req.push_back(0x01);
                    req.push_back(0x00);
                    req.push_back(0x03);
                    req.push_back(static_cast<uint8_t>(destHost.size()));
                    req.insert(req.end(), destHost.begin(), destHost.end());
                    req.push_back(static_cast<uint8_t>((destPort >> 8) & 0xff));
                    req.push_back(static_cast<uint8_t>(destPort & 0xff));
                    if (!WriteAll(fd, req.data(), req.size(), timeoutMs)) {
                        msg = "socks connect write failed";
                    } else {
                        ssize_t n = ReadSome(fd, buf, sizeof(buf), timeoutMs);
                        if (n < 2 || buf[1] != 0x00) {
                            msg = "socks CONNECT failed status=" + std::to_string(n >= 2 ? buf[1] : -1);
                        } else {
                            std::string http = "GET / HTTP/1.1\r\nHost: " + destHost +
                                "\r\nUser-Agent: ss-ohos-probe\r\nConnection: close\r\n\r\n";
                            if (!WriteAll(fd, reinterpret_cast<const uint8_t *>(http.data()), http.size(), timeoutMs)) {
                                msg = "http write failed";
                            } else {
                                n = ReadSome(fd, buf, sizeof(buf) - 1, timeoutMs);
                                if (n <= 0) {
                                    msg = "http read failed";
                                } else {
                                    buf[n] = 0;
                                    std::string body(reinterpret_cast<char *>(buf), static_cast<size_t>(n));
                                    auto pos = body.find('\r');
                                    if (pos != std::string::npos) {
                                        body = body.substr(0, pos);
                                    }
                                    if (body.find("HTTP/") == 0) {
                                        msg = std::string("ok ") + body;
                                    } else {
                                        msg = std::string("unexpected: ") + body;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        close(fd);
    }

    OH_LOG_INFO(LOG_APP, "socksHttpGet %{public}s", msg.c_str());
    napi_value result;
    napi_create_string_utf8(env, msg.c_str(), msg.size(), &result);
    return result;
}

static void DnsPutName(std::vector<uint8_t> &q, const std::string &name)
{
    size_t i = 0;
    while (i < name.size()) {
        size_t j = name.find('.', i);
        if (j == std::string::npos) {
            j = name.size();
        }
        uint8_t lab = static_cast<uint8_t>(j - i);
        q.push_back(lab);
        q.insert(q.end(), name.begin() + static_cast<std::ptrdiff_t>(i),
            name.begin() + static_cast<std::ptrdiff_t>(j));
        if (j >= name.size()) {
            break;
        }
        i = j + 1;
    }
    q.push_back(0);
}

static napi_value NapiDnsQuery(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return ThrowError(env, "dnsQuery(host, port, name, timeoutMs) required");
    }
    std::string host = GetString(env, argv[0]);
    int32_t port = 0;
    std::string name = GetString(env, argv[2]);
    int32_t timeoutMs = 5000;
    napi_get_value_int32(env, argv[1], &port);
    if (argc >= 4) {
        napi_get_value_int32(env, argv[3], &timeoutMs);
    }

    std::string msg = "fail";
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        msg = std::string("socket: ") + strerror(errno);
    } else {
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(port));
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
        std::vector<uint8_t> q;
        q.push_back(0x12);
        q.push_back(0x34);
        q.push_back(0x01);
        q.push_back(0x00);
        q.push_back(0x00);
        q.push_back(0x01);
        q.push_back(0x00);
        q.push_back(0x00);
        q.push_back(0x00);
        q.push_back(0x00);
        q.push_back(0x00);
        q.push_back(0x00);
        DnsPutName(q, name);
        q.push_back(0x00);
        q.push_back(0x01);
        q.push_back(0x00);
        q.push_back(0x01);
        ssize_t sent = sendto(fd, q.data(), q.size(), 0, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
        if (sent < 0) {
            msg = std::string("sendto: ") + strerror(errno);
        } else if (!WaitReadable(fd, timeoutMs)) {
            msg = "dns timeout";
        } else {
            uint8_t buf[512] {};
            ssize_t n = recvfrom(fd, buf, sizeof(buf), 0, nullptr, nullptr);
            if (n < 12) {
                msg = "dns short reply";
            } else if ((buf[3] & 0x0f) != 0) {
                msg = "dns rcode=" + std::to_string(buf[3] & 0x0f);
            } else {
                int an = (buf[6] << 8) | buf[7];
                msg = std::string("ok answers=") + std::to_string(an) + " bytes=" + std::to_string(n);
            }
        }
        close(fd);
    }
    OH_LOG_INFO(LOG_APP, "dnsQuery %{public}s:%{public}d %{public}s -> %{public}s", host.c_str(), port, name.c_str(),
        msg.c_str());
    napi_value result;
    napi_create_string_utf8(env, msg.c_str(), msg.size(), &result);
    return result;
}

static napi_value NapiClearCloexec(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = -1;
    napi_get_value_int32(env, argv[0], &fd);
    if (fd >= 0) {
        int fdFlags = fcntl(fd, F_GETFD);
        if (fdFlags >= 0) {
            fcntl(fd, F_SETFD, fdFlags & ~FD_CLOEXEC);
        }
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0) {
            fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
        }
    }
    napi_value result;
    napi_create_int32(env, fd, &result);
    return result;
}

static napi_value NapiDupFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = -1;
    napi_get_value_int32(env, argv[0], &fd);
    int duped = -1;
    if (fd >= 0) {
        duped = dup(fd);
        if (duped >= 0) {
            int fdFlags = fcntl(duped, F_GETFD);
            if (fdFlags >= 0) {
                fcntl(duped, F_SETFD, fdFlags & ~FD_CLOEXEC);
            }
            int fl = fcntl(duped, F_GETFL);
            if (fl >= 0) {
                fcntl(duped, F_SETFL, fl & ~O_NONBLOCK);
            }
        }
    }
    napi_value result;
    napi_create_int32(env, duped, &result);
    return result;
}

static napi_value NapiStartSsClient(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
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
        return ThrowError(env, std::string("load libssengine.so failed: ") + g_engineStatus);
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
    int rc = g_startClient(ss.data(), socks.data(), udp.data(), tcp.data(), 1, errBuf, sizeof(errBuf));
    if (rc != 0) {
        std::string msg = errBuf[0] ? errBuf : "SsStartClient failed";
        OH_LOG_ERROR(LOG_APP, "SsStartClient failed: %{public}s", msg.c_str());
        return ThrowError(env, msg);
    }
    OH_LOG_INFO(LOG_APP, "SsStartClient ok socks=%{public}s", socksAddr.c_str());
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
        return ThrowError(env, std::string("load libssengine.so failed: ") + g_engineStatus);
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
        OH_LOG_ERROR(LOG_APP, "SsStartTun2Socks failed: %{public}s", msg.c_str());
        return ThrowError(env, msg);
    }
    OH_LOG_INFO(LOG_APP, "SsStartTun2Socks ok fd=%{public}d", tunFd);
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

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_attributes attr = static_cast<napi_property_attributes>(
        napi_writable | napi_enumerable | napi_configurable);
    napi_property_descriptor desc[] = {
        {"spawn", nullptr, NapiSpawn, nullptr, nullptr, nullptr, attr, nullptr},
        {"killPid", nullptr, NapiKillPid, nullptr, nullptr, nullptr, attr, nullptr},
        {"isAlive", nullptr, NapiIsAlive, nullptr, nullptr, nullptr, attr, nullptr},
        {"chmodPath", nullptr, NapiChmod, nullptr, nullptr, nullptr, attr, nullptr},
        {"waitPort", nullptr, NapiWaitPort, nullptr, nullptr, nullptr, attr, nullptr},
        {"socksHttpGet", nullptr, NapiSocksHttpGet, nullptr, nullptr, nullptr, attr, nullptr},
        {"dnsQuery", nullptr, NapiDnsQuery, nullptr, nullptr, nullptr, attr, nullptr},
        {"clearCloexec", nullptr, NapiClearCloexec, nullptr, nullptr, nullptr, attr, nullptr},
        {"dupFd", nullptr, NapiDupFd, nullptr, nullptr, nullptr, attr, nullptr},
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
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSscoreModule()
{
    napi_module_register(&g_module);
}
