#include "napi_common.h"
#include "smb_ops.h"
#include <string>
#include <chrono>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <memory>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <algorithm>
#include <cctype>
#include <climits>
#include <limits>
#include <thread>
#include <atomic>
#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/avplayer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#if VIDALL_HAS_VPE
#include <multimedia/video_processing_engine/video_processing.h>
#include <multimedia/video_processing_engine/video_processing_types.h>
#endif // VIDALL_HAS_VPE
#include <hilog/log.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
}
#if VIDALL_HAS_LIBCURL
#include <curl/curl.h>
#endif
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#if VIDALL_HAS_LIBSMB2
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/libsmb2-dcerpc-srvsvc.h>
#endif
namespace vidall {

// ============================================================================
// SMB Protocol NAPI Functions
// ============================================================================

#if VIDALL_HAS_LIBSMB2

// ── 异步上下文：SmbTestConnection ──────────────────────────────────────────
struct SmbConnTestContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    std::string shareName;
    int64_t timeoutMs = 5000;
    bool success = false;
    std::string errorMessage;
};

static void ExecuteSmbTestConnection(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbConnTestContext *>(data);

    // ── TCP 预检：验证 host:port 是否可达，排除网络层问题 ──────────────────
    {
        int tcpFd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (tcpFd < 0) {
            ctx->errorMessage = std::string("socket() failed, errno:") + std::to_string(errno)
                                + " (" + std::strerror(errno) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check: socket() failed errno=%{public}d", errno);
            return;
        }
        // 设置连接超时（非阻塞 connect + poll）
        int flags = ::fcntl(tcpFd, F_GETFL, 0);
        ::fcntl(tcpFd, F_SETFL, flags | O_NONBLOCK);

        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port   = htons((uint16_t)ctx->port);
        if (::inet_pton(AF_INET, ctx->host.c_str(), &addr.sin_addr) != 1) {
            // 非纯 IPv4 字面量（主机名/IPv6），跳过 TCP 预检，由 libsmb2 自行解析
            ::close(tcpFd);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient",
                "TCP pre-check skipped (not IPv4 literal), host=%{public}s", ctx->host.c_str());
        } else {

        int connRet = ::connect(tcpFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (connRet < 0 && errno != EINPROGRESS) {
            int savedErrno = errno;
            ::close(tcpFd);
            ctx->errorMessage = std::string("TCP connect() failed, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + " errno:" + std::to_string(savedErrno)
                                + " (" + std::strerror(savedErrno) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check failed errno=%{public}d host=%{public}s port=%{public}lld",
                        savedErrno, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        // 等待连接完成
        int timeoutMs = (ctx->timeoutMs > 0 && ctx->timeoutMs < 10000) ? (int)ctx->timeoutMs : 5000;
        struct pollfd pfd{};
        pfd.fd = tcpFd;
        pfd.events = POLLOUT;
        int pollRet = ::poll(&pfd, 1, timeoutMs);
        if (pollRet <= 0) {
            ::close(tcpFd);
            ctx->errorMessage = std::string("TCP connect timeout/error, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + (pollRet == 0 ? " (timed out)" : " (poll error)");
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check poll ret=%{public}d host=%{public}s port=%{public}lld",
                        pollRet, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        // 检查 SO_ERROR
        int soErr = 0;
        socklen_t soErrLen = sizeof(soErr);
        int gsRet = ::getsockopt(tcpFd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen);
        ::close(tcpFd);
        if (gsRet != 0 || soErr != 0) {
            int finalErr = (gsRet != 0) ? errno : soErr;
            ctx->errorMessage = std::string("TCP connect refused/error, host=") + ctx->host
                                + " port=" + std::to_string(ctx->port)
                                + " errno:" + std::to_string(finalErr)
                                + " (" + std::strerror(finalErr) + ")";
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "TCP pre-check SO_ERROR=%{public}d host=%{public}s port=%{public}lld",
                        finalErr, ctx->host.c_str(), (long long)ctx->port);
            return;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient", "TCP pre-check OK host=%{public}s port=%{public}lld",
                    ctx->host.c_str(), (long long)ctx->port);
        } // end IPv4 pre-check else
    }


    // ── libsmb2 连接 ──────────────────────────────────────────────────────
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 5;
    if (timeoutSec < 1) timeoutSec = 1;
    smb2_set_timeout(smb2, timeoutSec);
    // 当 shareName 为空时，连接 IPC$（纯认证验证，不依赖具体共享名）
    const char *connectShare = ctx->shareName.empty() ? "IPC$" : ctx->shareName.c_str();
    int ret = smb2_connect_share(smb2, BuildSmbConnectHost(ctx->host, ctx->port).c_str(), connectShare,
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smb2_connect_share failed: %{public}s", ctx->errorMessage.c_str());
    } else {
        ctx->success = true;
        smb2_disconnect_share(smb2);
    }
    smb2_destroy_context(smb2);
}

static void CompleteSmbTestConnection(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbConnTestContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value successVal = nullptr;
    napi_get_boolean(env, ctx->success, &successVal);
    napi_set_named_property(env, result, "success", successVal);
    if (!ctx->success && !ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

// ── 异步上下文：SmbListDirectory ───────────────────────────────────────────
struct SmbFileEntry {
    std::string name;
    std::string path;           // 完整相对路径（dirPath/name），由 ArkTS 层基于 shareName+subPath 拼接
    bool isDirectory = false;
    uint64_t size = 0;
    uint64_t lastModified = 0;  // Unix epoch 毫秒（ms），对齐 ArkTS 侧 lastModifiedMs
};

struct SmbListDirContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    std::string shareName;
    std::string path;
    int64_t timeoutMs = 10000;
    std::vector<SmbFileEntry> files;
    std::string errorMessage;
};

static inline uint64_t SmbTimeToUnixMilliseconds(uint64_t seconds, uint64_t nanoseconds) {
    constexpr uint64_t NANOSECONDS_PER_SECOND = 1000000000ULL;
    constexpr uint64_t NANOSECONDS_PER_MILLISECOND = 1000000ULL;
    const uint64_t fractionalMilliseconds = nanoseconds / NANOSECONDS_PER_MILLISECOND;
    if (nanoseconds >= NANOSECONDS_PER_SECOND ||
        seconds > (std::numeric_limits<uint64_t>::max() - fractionalMilliseconds) / 1000ULL) {
        return 0;
    }
    return seconds * 1000ULL + fractionalMilliseconds;
}

static void ExecuteSmbListDirectory(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbListDirContext *>(data);
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 10;
    if (timeoutSec < 1) timeoutSec = 1;
    smb2_set_timeout(smb2, timeoutSec);
    int ret = smb2_connect_share(smb2, BuildSmbConnectHost(ctx->host, ctx->port).c_str(), ctx->shareName.c_str(),
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        smb2_destroy_context(smb2);
        return;
    }
    // 空字符串表示 share 根目录（libsmb2 期望 ""，传 "/" 会触发 Windows STATUS_INVALID_PARAMETER）
    const char *dirPath = ctx->path.c_str();
    struct smb2dir *dir = smb2_opendir(smb2, dirPath);
    if (!dir) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "opendir failed";
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }
    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2, dir)) != nullptr) {
        if (!ent->name) continue;
        if (std::strcmp(ent->name, ".") == 0 || std::strcmp(ent->name, "..") == 0) continue;
        SmbFileEntry entry;
        entry.name = ent->name;
        // 构造完整路径：dir/name（ArkTS 层不应再 re-derive）
        {
            std::string base = dirPath;
            while (!base.empty() && base.back() == '/') base.pop_back();
            entry.path = base + "/" + ent->name;
        }
        entry.isDirectory = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
        entry.size = ent->st.smb2_size;
        entry.lastModified = SmbTimeToUnixMilliseconds(ent->st.smb2_mtime, ent->st.smb2_mtime_nsec);
        ctx->files.push_back(std::move(entry));
    }
    smb2_closedir(smb2, dir);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
}

// ── 异步上下文：SmbListShares ──────────────────────────────────────────────
struct SmbShareEntry {
    std::string name;
    std::string remark;
    uint32_t type = 0;
};

struct SmbListSharesContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int64_t port = 445;
    std::string username;
    std::string password;
    std::string domain;
    int64_t timeoutMs = 10000;
    std::vector<SmbShareEntry> shares;
    std::string errorMessage;
};

static void ExecuteSmbListShares(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbListSharesContext *>(data);
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!ctx->username.empty()) smb2_set_user(smb2, ctx->username.c_str());
    if (!ctx->password.empty()) smb2_set_password(smb2, ctx->password.c_str());
    if (!ctx->domain.empty()) smb2_set_domain(smb2, ctx->domain.c_str());
    int timeoutSec = (ctx->timeoutMs > 0) ? (int)(ctx->timeoutMs / 1000) : 10;
    if (timeoutSec < 1) timeoutSec = 1;
    smb2_set_timeout(smb2, timeoutSec);

    // 连接到 IPC$ 共享（SMB 共享枚举的标准路径）
    int ret = smb2_connect_share(smb2, BuildSmbConnectHost(ctx->host, ctx->port).c_str(), "IPC$",
                                  ctx->username.empty() ? nullptr : ctx->username.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "Failed to connect to IPC$";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smbListShares IPC$ connect failed: %{public}s", ctx->errorMessage.c_str());
        smb2_destroy_context(smb2);
        return;
    }

    struct srvsvc_NetrShareEnum_rep *rep = smb2_share_enum_sync(smb2, SHARE_INFO_1);
    if (!rep) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_share_enum failed";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, "SMBClient", "smbListShares enum failed: %{public}s", ctx->errorMessage.c_str());
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    uint32_t count = rep->ses.ShareInfo.Level1.EntriesRead;
    struct srvsvc_SHARE_INFO_1_carray *buf = rep->ses.ShareInfo.Level1.Buffer;
    for (uint32_t i = 0; i < count && buf; i++) {
        struct srvsvc_SHARE_INFO_1 &si = buf->share_info_1[i];
        SmbShareEntry entry;
        entry.name   = si.netname.utf8 ? si.netname.utf8 : "";
        entry.remark = si.remark.utf8  ? si.remark.utf8  : "";
        entry.type   = si.type;
        ctx->shares.push_back(std::move(entry));
    }
    smb2_free_data(smb2, rep);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
}

static void CompleteSmbListShares(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbListSharesContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value sharesArr = nullptr;
    napi_create_array_with_length(env, ctx->shares.size(), &sharesArr);
    for (size_t i = 0; i < ctx->shares.size(); i++) {
        const auto &s = ctx->shares[i];
        napi_value shareObj = nullptr;
        napi_create_object(env, &shareObj);
        napi_value nm = nullptr;
        napi_create_string_utf8(env, s.name.c_str(), NAPI_AUTO_LENGTH, &nm);
        napi_set_named_property(env, shareObj, "name", nm);
        napi_value rmk = nullptr;
        napi_create_string_utf8(env, s.remark.c_str(), NAPI_AUTO_LENGTH, &rmk);
        napi_set_named_property(env, shareObj, "remark", rmk);
        napi_value tp = nullptr;
        napi_create_uint32(env, s.type, &tp);
        napi_set_named_property(env, shareObj, "type", tp);
        napi_set_element(env, sharesArr, (uint32_t)i, shareObj);
    }
    napi_set_named_property(env, result, "shares", sharesArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static void CompleteSmbListDirectory(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbListDirContext *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value filesArr = nullptr;
    napi_create_array_with_length(env, ctx->files.size(), &filesArr);
    for (size_t i = 0; i < ctx->files.size(); i++) {
        const auto &f = ctx->files[i];
        napi_value fileObj = nullptr;
        napi_create_object(env, &fileObj);
        napi_value nm = nullptr;
        napi_create_string_utf8(env, f.name.c_str(), NAPI_AUTO_LENGTH, &nm);
        napi_set_named_property(env, fileObj, "name", nm);
        napi_value pathVal = nullptr;
        napi_create_string_utf8(env, f.path.c_str(), NAPI_AUTO_LENGTH, &pathVal);
        napi_set_named_property(env, fileObj, "path", pathVal);
        napi_value isDir = nullptr;
        napi_get_boolean(env, f.isDirectory, &isDir);
        napi_set_named_property(env, fileObj, "isDirectory", isDir);
        napi_value sz = nullptr;
        napi_create_int64(env, (int64_t)f.size, &sz);
        napi_set_named_property(env, fileObj, "size", sz);
        napi_value lm = nullptr;
        napi_create_int64(env, (int64_t)f.lastModified, &lm);
        napi_set_named_property(env, fileObj, "lastModified", lm);
        napi_set_element(env, filesArr, (uint32_t)i, fileObj);
    }
    napi_set_named_property(env, result, "files", filesArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

// ── 异步上下文：SmbReadTextFile ─────────────────────────────────────────────
struct SmbReadTextFileContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string url;           // 完整 smb:// URL（含凭据，仅在 Execute 内部使用，不打印）
    int64_t maxSizeBytes = 5 * 1024 * 1024;
    int32_t timeoutSeconds = 5; // Fix C: 可配置超时，默认 5s（原硬编码 30s）
    std::string content;       // 读取结果：UTF-8 文本内容
    std::string errorMessage;
};

static void ExecuteSmbReadTextFile(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbReadTextFileContext *>(data);
    SmbUrlComponents comps = ParseSmbUrl(ctx->url);
    if (!comps.valid) {
        ctx->errorMessage = "smbReadTextFile: invalid SMB URL";
        return;
    }
    // 脱敏日志：只打印 host + share + subPath，不打印凭据
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient",
                 "smbReadTextFile: host=%{public}s share=%{public}s path=%{public}s",
                 comps.host.c_str(), comps.share.c_str(), comps.subPath.c_str());

    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!comps.user.empty())     smb2_set_user(smb2, comps.user.c_str());
    if (!comps.password.empty()) smb2_set_password(smb2, comps.password.c_str());
    smb2_set_timeout(smb2, ctx->timeoutSeconds); // Fix C: 使用可配置超时（原硬编码 30s）

    int ret = smb2_connect_share(smb2, BuildSmbConnectHost(comps.host, comps.port).c_str(), comps.share.c_str(),
                                  comps.user.empty() ? nullptr : comps.user.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        smb2_destroy_context(smb2);
        return;
    }

    struct smb2fh *fh = smb2_open(smb2, comps.subPath.c_str(), O_RDONLY);
    if (!fh) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_open failed";
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    struct smb2_stat_64 st;
    if (smb2_fstat(smb2, fh, &st) < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_fstat failed";
        smb2_close(smb2, fh);
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    uint64_t fileSize = st.smb2_size;
    // Fix E: uint64_t 比较，避免 int64_t 转换溢出
    if (fileSize > (uint64_t)ctx->maxSizeBytes) {
        ctx->errorMessage = "smbReadTextFile: file size " + std::to_string(fileSize) +
                            " bytes exceeds maxSizeBytes " + std::to_string(ctx->maxSizeBytes);
        smb2_close(smb2, fh);
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    // 分块读取全部内容到 std::string
    ctx->content.reserve((size_t)fileSize);
    const size_t kBufSize = 65536;
    std::vector<uint8_t> buf(kBufSize);
    int32_t bytesRead = 0;
    while ((bytesRead = smb2_read(smb2, fh, buf.data(), kBufSize)) > 0) {
        ctx->content.append(reinterpret_cast<const char *>(buf.data()), (size_t)bytesRead);
        // 二次防护：读取途中若超出限制则中止（Fix E: 使用 uint64_t 比较）
        if (ctx->content.size() > (uint64_t)ctx->maxSizeBytes) {
            ctx->errorMessage = "smbReadTextFile: data exceeded maxSizeBytes during read";
            ctx->content.clear();
            smb2_close(smb2, fh);
            smb2_disconnect_share(smb2);
            smb2_destroy_context(smb2);
            return;
        }
    }
    if (bytesRead < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_read failed";
        ctx->content.clear();
        smb2_close(smb2, fh);
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    smb2_close(smb2, fh);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient",
                 "smbReadTextFile: read %{public}zu bytes from %{public}s/%{public}s",
                 ctx->content.size(), comps.share.c_str(), comps.subPath.c_str());
}

static void CompleteSmbReadTextFile(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbReadTextFileContext *>(data);
    if (!ctx->errorMessage.empty()) {
        // Fix D: reject with Error object (not raw string), consistent with ffprobe interface
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_value errObj = nullptr;
        if (napi_create_error(env, nullptr, errMsg, &errObj) == napi_ok) {
            napi_reject_deferred(env, ctx->deferred, errObj);
        } else {
            napi_reject_deferred(env, ctx->deferred, errMsg);
        }
    } else {
        napi_value contentVal = nullptr;
        if (napi_create_string_utf8(env, ctx->content.c_str(), ctx->content.size(), &contentVal) != napi_ok) {
            // Fix D: reject with Error object for internal error too
            napi_value errMsg = nullptr;
            napi_create_string_utf8(env, "NAPI internal error: failed to create content string",
                                    NAPI_AUTO_LENGTH, &errMsg);
            napi_value errObj = nullptr;
            if (napi_create_error(env, nullptr, errMsg, &errObj) == napi_ok) {
                napi_reject_deferred(env, ctx->deferred, errObj);
            } else {
                napi_reject_deferred(env, ctx->deferred, errMsg);
            }
        } else {
            napi_resolve_deferred(env, ctx->deferred, contentVal);
        }
    }
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

struct SmbDownloadFileContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string url;
    std::string outputPath;
    int32_t timeoutSeconds = 15;
    std::string errorMessage;
};

static void ExecuteSmbDownloadFile(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbDownloadFileContext *>(data);
    SmbUrlComponents comps = ParseSmbUrl(ctx->url);
    if (!comps.valid) {
        ctx->errorMessage = "smbDownloadFile: invalid SMB URL";
        return;
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SMBClient",
                 "smbDownloadFile: host=%{public}s share=%{public}s path=%{public}s output=%{public}s",
                 comps.host.c_str(), comps.share.c_str(), comps.subPath.c_str(), ctx->outputPath.c_str());

    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        ctx->errorMessage = "smb2_init_context failed (out of memory)";
        return;
    }
    if (!comps.user.empty())     smb2_set_user(smb2, comps.user.c_str());
    if (!comps.password.empty()) smb2_set_password(smb2, comps.password.c_str());
    smb2_set_timeout(smb2, ctx->timeoutSeconds);

    int ret = smb2_connect_share(smb2, BuildSmbConnectHost(comps.host, comps.port).c_str(), comps.share.c_str(),
                                 comps.user.empty() ? nullptr : comps.user.c_str());
    if (ret < 0) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "SMB connection failed";
        smb2_destroy_context(smb2);
        return;
    }

    struct smb2fh *fh = smb2_open(smb2, comps.subPath.c_str(), O_RDONLY);
    if (!fh) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_open failed";
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    FILE *outputFile = std::fopen(ctx->outputPath.c_str(), "wb");
    if (!outputFile) {
        ctx->errorMessage = "smbDownloadFile: failed to open output file";
        smb2_close(smb2, fh);
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return;
    }

    const size_t kBufSize = 65536;
    std::vector<uint8_t> buf(kBufSize);
    int32_t bytesRead = 0;
    while ((bytesRead = smb2_read(smb2, fh, buf.data(), kBufSize)) > 0) {
        size_t bytesWritten = std::fwrite(buf.data(), 1, static_cast<size_t>(bytesRead), outputFile);
        if (bytesWritten != static_cast<size_t>(bytesRead)) {
            ctx->errorMessage = "smbDownloadFile: failed to write output file";
            break;
        }
    }
    if (bytesRead < 0 && ctx->errorMessage.empty()) {
        const char *errStr = smb2_get_error(smb2);
        ctx->errorMessage = (errStr && errStr[0]) ? errStr : "smb2_read failed";
    }

    std::fclose(outputFile);
    smb2_close(smb2, fh);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);

    if (!ctx->errorMessage.empty()) {
        std::remove(ctx->outputPath.c_str());
        return;
    }
}

static void CompleteSmbDownloadFile(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbDownloadFileContext *>(data);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_value errObj = nullptr;
        if (napi_create_error(env, nullptr, errMsg, &errObj) == napi_ok) {
            napi_reject_deferred(env, ctx->deferred, errObj);
        } else {
            napi_reject_deferred(env, ctx->deferred, errMsg);
        }
    } else {
        napi_value outputPathVal = nullptr;
        if (napi_create_string_utf8(env, ctx->outputPath.c_str(), NAPI_AUTO_LENGTH, &outputPathVal) == napi_ok) {
            napi_resolve_deferred(env, ctx->deferred, outputPathVal);
        } else {
            napi_value errMsg = nullptr;
            napi_create_string_utf8(env, "NAPI internal error: failed to create output path string",
                                    NAPI_AUTO_LENGTH, &errMsg);
            napi_value errObj = nullptr;
            if (napi_create_error(env, nullptr, errMsg, &errObj) == napi_ok) {
                napi_reject_deferred(env, ctx->deferred, errObj);
            } else {
                napi_reject_deferred(env, ctx->deferred, errMsg);
            }
        }
    }
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

#endif // VIDALL_HAS_LIBSMB2

/**
 * smbListShares(host, port, username, password, domain, timeoutMs)
 * -> Promise<{ shares: Array<{name, remark, type}>, error?: string }>
 *
 * 连接到服务器的 IPC$ 共享，枚举所有磁盘共享（type & 3 == SHARE_TYPE_DISKTREE）。
 * 不需要预先知道共享名。
 */
napi_value SmbListShares(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbListShares failed to read args");
        return nullptr;
    }
    if (argc < 6) {
        ThrowTypeError(env, "smbListShares requires (host, port, username, password, domain, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbListShares host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbListShares port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbListShares username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbListShares password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbListShares domain must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[5], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbListShares timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbListShares failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbListSharesContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbListSharesAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbListShares, CompleteSmbListShares,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbListShares failed to queue async work");
            return nullptr;
        }
    }
#else
    {
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_value sharesArr = nullptr;
        napi_create_array(env, &sharesArr);
        napi_set_named_property(env, result, "shares", sharesArr);
        napi_value errorMsg = nullptr;
        napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg);
        napi_set_named_property(env, result, "error", errorMsg);
        napi_resolve_deferred(env, deferred, result);
    }
#endif

    return promise;
}


/**
 * smbDiscoverHosts(subnetPrefix, startOctet, endOctet, port, timeoutMs)
 * -> Promise<{ hosts: string[]; error?: string }>
 *
 * 并发扫描指定子网（subnetPrefix + startOctet..endOctet）的 TCP 端口，
 * 返回在 timeoutMs 内成功建立连接的主机 IP 列表。
 * 不依赖 libsmb2，使用纯 POSIX socket。
 */
struct SmbDiscoverCtx {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string subnetPrefix;   // 如 "192.168.3."
    int startOctet = 1;
    int endOctet = 254;
    int port = 445;
    int timeoutMs = 3000;
    std::vector<std::string> hosts;
    std::string errorMessage;
};

static void ExecuteSmbDiscoverHosts(napi_env /*env*/, void *data) {
    auto *ctx = static_cast<SmbDiscoverCtx *>(data);

    struct Probe {
        int fd = -1;
        std::string ip;
        bool done = false;
    };

    int count = ctx->endOctet - ctx->startOctet + 1;
    if (count <= 0) return;

    std::vector<Probe> probes(count);
    for (int i = 0; i < count; i++) {
        int octet = ctx->startOctet + i;
        std::string ip = ctx->subnetPrefix + std::to_string(octet);
        int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) continue;
        // 非阻塞
        int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            ::close(fd);
            continue;
        }
        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)ctx->port);
        if (::inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
            ::close(fd);
            continue;
        }
        ::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
        probes[i] = { fd, ip, false };
    }

    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(ctx->timeoutMs);

    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) break;

        auto remMs = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
        int pollTimeout = (int)std::min(remMs, (long long)100);

        std::vector<struct pollfd> pfds;
        std::vector<int> indices;
        pfds.reserve(count);
        indices.reserve(count);
        for (int j = 0; j < count; j++) {
            if (!probes[j].done && probes[j].fd >= 0) {
                struct pollfd pfd{};
                pfd.fd = probes[j].fd;
                pfd.events = POLLOUT;
                pfds.push_back(pfd);
                indices.push_back(j);
            }
        }
        if (pfds.empty()) break;

        int n = ::poll(pfds.data(), (nfds_t)pfds.size(), pollTimeout);
        if (n < 0) continue;

        for (size_t k = 0; k < pfds.size(); k++) {
            if (pfds[k].revents & (POLLOUT | POLLERR | POLLHUP)) {
                int j = indices[k];
                probes[j].done = true;
                int err = 0;
                socklen_t errlen = sizeof(err);
                if (::getsockopt(pfds[k].fd, SOL_SOCKET, SO_ERROR, &err, &errlen) == 0 && err == 0) {
                    ctx->hosts.push_back(probes[j].ip);
                }
                ::close(pfds[k].fd);
                probes[j].fd = -1;
            }
        }
    }

    for (auto &p : probes) {
        if (p.fd >= 0) ::close(p.fd);
    }
}

static void CompleteSmbDiscoverHosts(napi_env env, napi_status /*status*/, void *data) {
    auto *ctx = static_cast<SmbDiscoverCtx *>(data);
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) {
        napi_value errStr = nullptr;
        napi_create_string_utf8(env, "NAPI internal error: failed to create result object",
                                NAPI_AUTO_LENGTH, &errStr);
        napi_reject_deferred(env, ctx->deferred, errStr);
        if (ctx->work) napi_delete_async_work(env, ctx->work);
        delete ctx;
        return;
    }
    napi_value hostsArr = nullptr;
    napi_create_array_with_length(env, ctx->hosts.size(), &hostsArr);
    for (size_t i = 0; i < ctx->hosts.size(); i++) {
        napi_value ipVal = nullptr;
        napi_create_string_utf8(env, ctx->hosts[i].c_str(), NAPI_AUTO_LENGTH, &ipVal);
        napi_set_element(env, hostsArr, (uint32_t)i, ipVal);
    }
    napi_set_named_property(env, result, "hosts", hostsArr);
    if (!ctx->errorMessage.empty()) {
        napi_value errMsg = nullptr;
        napi_create_string_utf8(env, ctx->errorMessage.c_str(), NAPI_AUTO_LENGTH, &errMsg);
        napi_set_named_property(env, result, "error", errMsg);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    if (ctx->work) napi_delete_async_work(env, ctx->work);
    delete ctx;
}

napi_value SmbDiscoverHosts(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 5) {
        ThrowTypeError(env, "smbDiscoverHosts requires (subnetPrefix, startOctet, endOctet, port, timeoutMs)");
        return nullptr;
    }
    std::string subnetPrefix;
    int64_t startOctet = 0, endOctet = 0, port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], subnetPrefix)) {
        ThrowTypeError(env, "smbDiscoverHosts subnetPrefix must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &startOctet) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts startOctet must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[2], &endOctet) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts endOctet must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[3], &port) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts port must be int64");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[4], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts timeoutMs must be int64");
        return nullptr;
    }
    // 参数范围校验，防止 FD/内存耗尽
    if (startOctet < 0 || startOctet > 255 || endOctet < 0 || endOctet > 255 || endOctet < startOctet) {
        ThrowTypeError(env, "smbDiscoverHosts: octet must be in [0,255] with startOctet <= endOctet");
        return nullptr;
    }
    if (endOctet - startOctet + 1 > 254) {
        ThrowTypeError(env, "smbDiscoverHosts: scan range too large (max 254 hosts)");
        return nullptr;
    }
    if (port < 1 || port > 65535) {
        ThrowTypeError(env, "smbDiscoverHosts: port must be in [1,65535]");
        return nullptr;
    }
    if (timeoutMs <= 0 || timeoutMs > 30000) {
        ThrowTypeError(env, "smbDiscoverHosts: timeoutMs must be in (0, 30000]");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbDiscoverHosts failed to create promise");
        return nullptr;
    }

    auto *ctx = new SmbDiscoverCtx();
    ctx->deferred = deferred;
    ctx->subnetPrefix = subnetPrefix;
    ctx->startOctet = (int)startOctet;
    ctx->endOctet = (int)endOctet;
    ctx->port = (int)port;
    ctx->timeoutMs = (int)timeoutMs;

    napi_value resourceName = nullptr;
    if (napi_create_string_utf8(env, "smbDiscoverHostsAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to create resource name");
        return nullptr;
    }
    if (napi_create_async_work(env, nullptr, resourceName,
                               ExecuteSmbDiscoverHosts, CompleteSmbDiscoverHosts,
                               ctx, &ctx->work) != napi_ok) {
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to create async work");
        return nullptr;
    }
    if (napi_queue_async_work(env, ctx->work) != napi_ok) {
        napi_delete_async_work(env, ctx->work);
        delete ctx;
        ThrowTypeError(env, "smbDiscoverHosts failed to queue async work");
        return nullptr;
    }
    return promise;
}

/**
 * smbTestConnection(host, port, username, password, domain, shareName, timeoutMs)
 * -> Promise<{ success: boolean; error?: string; serverInfo?: string }>
 *
 * 阶段一（VIDALL_HAS_LIBSMB2=0）：返回未实现提示
 * 阶段二（VIDALL_HAS_LIBSMB2=1）：调用 libsmb2 真实连接
 */
napi_value SmbTestConnection(napi_env env, napi_callback_info info) {
    // ── 参数校验（仿照 Ffprobe / WebdavRequest 模式）─────────────────────────
    size_t argc = 7;
    napi_value args[7] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection failed to read args");
        return nullptr;
    }
    if (argc < 7) {
        ThrowTypeError(env, "smbTestConnection requires (host, port, username, password, domain, shareName, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain, shareName;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbTestConnection host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbTestConnection username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbTestConnection password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbTestConnection domain must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[5], shareName)) {
        ThrowTypeError(env, "smbTestConnection shareName must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[6], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbTestConnection failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbConnTestContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->shareName = shareName;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbTestConnectionAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbTestConnection, CompleteSmbTestConnection,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbTestConnection failed to queue async work");
            return nullptr;
        }
    }
#else
    // libsmb2 未启用，返回明确的未实现状态
    {
        napi_value result = nullptr;
        if (napi_create_object(env, &result) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create result object");
            return nullptr;
        }
        napi_value successVal = nullptr;
        if (napi_get_boolean(env, false, &successVal) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create boolean");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "success", successVal) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to set success");
            return nullptr;
        }
        napi_value errorMsg = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to create error string");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "error", errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to set error");
            return nullptr;
        }
        if (napi_resolve_deferred(env, deferred, result) != napi_ok) {
            ThrowTypeError(env, "smbTestConnection failed to resolve deferred");
            return nullptr;
        }
    }
#endif

    return promise;
}

/**
 * smbListDirectory(host, port, username, password, domain, shareName, path, timeoutMs)
 * -> Promise<{ files: SmbFileInfo[]; error?: string }>
 *
 * SmbFileInfo: { name, path, isDirectory, size, lastModified }
 */
napi_value SmbListDirectory(napi_env env, napi_callback_info info) {
    // ── 参数校验（仿照 Ffprobe / WebdavRequest 模式）─────────────────────────
    size_t argc = 8;
    napi_value args[8] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory failed to read args");
        return nullptr;
    }
    if (argc < 8) {
        ThrowTypeError(env, "smbListDirectory requires (host, port, username, password, domain, shareName, path, timeoutMs)");
        return nullptr;
    }

    std::string host, username, password, domain, shareName, path;
    int64_t port = 0, timeoutMs = 0;
    if (!ReadUtf8String(env, args[0], host)) {
        ThrowTypeError(env, "smbListDirectory host must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &port) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory port must be int64");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[2], username)) {
        ThrowTypeError(env, "smbListDirectory username must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[3], password)) {
        ThrowTypeError(env, "smbListDirectory password must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[4], domain)) {
        ThrowTypeError(env, "smbListDirectory domain must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[5], shareName)) {
        ThrowTypeError(env, "smbListDirectory shareName must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[6], path)) {
        ThrowTypeError(env, "smbListDirectory path must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[7], &timeoutMs) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory timeoutMs must be int64");
        return nullptr;
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbListDirectory failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbListDirContext();
        ctx->deferred = deferred;
        ctx->host = host;
        ctx->port = port;
        ctx->username = username;
        ctx->password = password;
        ctx->domain = domain;
        ctx->shareName = shareName;
        ctx->path = path;
        ctx->timeoutMs = timeoutMs;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbListDirectoryAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbListDirectory, CompleteSmbListDirectory,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbListDirectory failed to queue async work");
            return nullptr;
        }
    }
#else
    // libsmb2 未启用，返回空文件列表和错误信息
    {
        napi_value result = nullptr;
        if (napi_create_object(env, &result) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create result object");
            return nullptr;
        }
        napi_value filesArr = nullptr;
        if (napi_create_array(env, &filesArr) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create files array");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "files", filesArr) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to set files property");
            return nullptr;
        }
        napi_value errorMsg = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not yet available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to create error string");
            return nullptr;
        }
        if (napi_set_named_property(env, result, "error", errorMsg) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to set error property");
            return nullptr;
        }
        if (napi_resolve_deferred(env, deferred, result) != napi_ok) {
            ThrowTypeError(env, "smbListDirectory failed to resolve deferred");
            return nullptr;
        }
    }
#endif

    return promise;
}

/**
 * smbReadTextFile(url: string, maxSizeBytes: number, timeoutSeconds?: number): Promise<string>
 *
 * 通过 SMB 协议读取小文件（如字幕文件）的 UTF-8 文本内容。
 * url 格式：smb://[user[:pass]@]host[:port]/share/path/to/file
 * maxSizeBytes：超过此大小则 reject（防止误读大文件）。
 * timeoutSeconds（可选，默认 5）：SMB 连接超时秒数，Fix C。
 */
napi_value SmbReadTextFile(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbReadTextFile failed to read args");
        return nullptr;
    }
    if (argc < 2) {
        ThrowTypeError(env, "smbReadTextFile requires (url, maxSizeBytes)");
        return nullptr;
    }

    std::string url;
    int64_t maxSizeBytes = 0;
    if (!ReadUtf8String(env, args[0], url)) {
        ThrowTypeError(env, "smbReadTextFile url must be string");
        return nullptr;
    }
    if (napi_get_value_int64(env, args[1], &maxSizeBytes) != napi_ok) {
        ThrowTypeError(env, "smbReadTextFile maxSizeBytes must be int64");
        return nullptr;
    }
    // Fix E: 校验 maxSizeBytes 范围 (0, 50MB]，越界时 clamp 到默认 5MB
    constexpr int64_t MAX_ALLOWED_BYTES = 50LL * 1024 * 1024;
    if (maxSizeBytes <= 0 || maxSizeBytes > MAX_ALLOWED_BYTES) {
        maxSizeBytes = 5LL * 1024 * 1024;
    }

    // Fix C: 读取可选第 3 个参数 timeoutSeconds，默认 5s
    int32_t timeoutSeconds = 5;
    if (argc >= 3 && args[2] != nullptr) {
        int64_t ts = 0;
        if (napi_get_value_int64(env, args[2], &ts) == napi_ok && ts > 0 && ts <= 300) {
            timeoutSeconds = (int32_t)ts;
        }
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbReadTextFile failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbReadTextFileContext();
        ctx->deferred = deferred;
        ctx->url = url;
        ctx->maxSizeBytes = maxSizeBytes;
        ctx->timeoutSeconds = timeoutSeconds; // Fix C

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbReadTextFileAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbReadTextFile failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbReadTextFile, CompleteSmbReadTextFile,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbReadTextFile failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbReadTextFile failed to queue async work");
            return nullptr;
        }
    }
#else
    {
        napi_value errorMsg = nullptr;
        napi_value errorObj = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) == napi_ok &&
            napi_create_error(env, nullptr, errorMsg, &errorObj) == napi_ok) {
            napi_reject_deferred(env, deferred, errorObj);
        }
    }
#endif

    return promise;
}

napi_value SmbDownloadFile(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        ThrowTypeError(env, "smbDownloadFile failed to read args");
        return nullptr;
    }
    if (argc < 2) {
        ThrowTypeError(env, "smbDownloadFile requires (url, outputPath)");
        return nullptr;
    }

    std::string url;
    std::string outputPath;
    if (!ReadUtf8String(env, args[0], url)) {
        ThrowTypeError(env, "smbDownloadFile url must be string");
        return nullptr;
    }
    if (!ReadUtf8String(env, args[1], outputPath)) {
        ThrowTypeError(env, "smbDownloadFile outputPath must be string");
        return nullptr;
    }

    int32_t timeoutSeconds = 15;
    if (argc >= 3 && args[2] != nullptr) {
        int64_t ts = 0;
        if (napi_get_value_int64(env, args[2], &ts) == napi_ok && ts > 0 && ts <= 300) {
            timeoutSeconds = static_cast<int32_t>(ts);
        }
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        ThrowTypeError(env, "smbDownloadFile failed to create promise");
        return nullptr;
    }

#if VIDALL_HAS_LIBSMB2
    {
        auto *ctx = new SmbDownloadFileContext();
        ctx->deferred = deferred;
        ctx->url = url;
        ctx->outputPath = outputPath;
        ctx->timeoutSeconds = timeoutSeconds;

        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "smbDownloadFileAsync", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbDownloadFile failed to create resource name");
            return nullptr;
        }
        if (napi_create_async_work(env, nullptr, resourceName,
                                   ExecuteSmbDownloadFile, CompleteSmbDownloadFile,
                                   ctx, &ctx->work) != napi_ok) {
            delete ctx;
            ThrowTypeError(env, "smbDownloadFile failed to create async work");
            return nullptr;
        }
        if (napi_queue_async_work(env, ctx->work) != napi_ok) {
            napi_delete_async_work(env, ctx->work);
            delete ctx;
            ThrowTypeError(env, "smbDownloadFile failed to queue async work");
            return nullptr;
        }
    }
#else
    {
        napi_value errorMsg = nullptr;
        napi_value errorObj = nullptr;
        if (napi_create_string_utf8(env,
            "SMB protocol not available: libsmb2 not compiled (VIDALL_HAS_LIBSMB2=0)",
            NAPI_AUTO_LENGTH, &errorMsg) == napi_ok &&
            napi_create_error(env, nullptr, errorMsg, &errorObj) == napi_ok) {
            napi_reject_deferred(env, deferred, errorObj);
        }
    }
#endif

    return promise;
}

} // namespace vidall
