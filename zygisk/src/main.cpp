/*
 * Render Switcher - per-process HWUI renderer isolation (v1.0.0, COW method)
 *
 * No PLT hooks.  The renderer properties are patched inside this process's
 * own private copy of the bionic property-area page(s) that hold them:
 *
 *   1. __system_property_find(name)      -> prop_info* inside /dev/__properties__/<ctx>
 *   2. find the mapping that contains it in /proc/self/maps
 *   3. mmap(MAP_PRIVATE|MAP_FIXED) of ONLY the page(s) holding that prop_info,
 *      same address, same file offset -> process-private copy-on-write pages
 *   4. write the new value + bump the per-property serial, seal read-only
 *
 * Every native and Java reader in the process (libhwui, libbase, libcutils,
 * libandroid_runtime, libc ...) then sees the override, regardless of which
 * library performs the read.  The shared property area is never modified.
 * Only the touched page(s) stop tracking later changes of neighbouring
 * properties in this process.
 *
 * Idea after device_faker (GPL-3) by Seyud; implementation written from scratch.
 */

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <fstream>
#include <map>
#include <pthread.h>
#include <sys/stat.h>
#include <string>
#include <string_view>
#include <vector>
#include <unistd.h>

#include <android/log.h>
#include <sys/system_properties.h>

#include "zygisk.hpp"

namespace {

constexpr const char *kTargetsPaths[] = {
    "/data/adb/modules/render_switcher/targets.conf",
    "/data/adb/render_switcher/config/targets.conf",
};
constexpr const char *kPropHwui = "debug.hwui.renderer";
constexpr const char *kPropVulkan = "ro.hwui.use_vulkan";
constexpr const char *kTag = "RenderSwitcher";
constexpr uint8_t OP_LOOKUP = 2;

static char g_override[PROP_VALUE_MAX];
static bool g_has_override = false;
static std::string g_pkg;

__attribute__((format(printf, 1, 2)))
void log_msg(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    __android_log_print(ANDROID_LOG_INFO, kTag, "%s", buf);
}

bool validRenderer(std::string_view r) {
    return r == "skiavk" || r == "skiagl";
}

bool validPackage(std::string_view pkg) {
    if (pkg.empty() || pkg.size() > 255) return false;
    if (pkg.front() == '.' || pkg.back() == '.') return false;
    if (pkg.find("..") != std::string_view::npos) return false;
    size_t segs = 0, i = 0;
    while (i < pkg.size()) {
        if (pkg[i] == '.') return false;
        if (!((pkg[i] >= 'A' && pkg[i] <= 'Z') ||
              (pkg[i] >= 'a' && pkg[i] <= 'z')))
            return false;
        while (i < pkg.size() && pkg[i] != '.') {
            char c = pkg[i];
            bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '_';
            if (!ok) return false;
            ++i;
        }
        ++segs;
        if (i < pkg.size() && pkg[i] == '.') ++i;
    }
    return segs >= 2;
}

/* One "pkg=renderer[:0|false|no|off]" line -> (pkg, renderer).
 * Returns false for blank/comment/invalid/disabled lines. */
bool parseTargetLine(std::string line, std::string *pkgOut,
                     std::string *rendererOut) {
    auto hash = line.find('#');
    if (hash != std::string::npos) line.resize(hash);
    while (!line.empty() &&
           (line.back() == ' ' || line.back() == '\t' || line.back() == '\r'))
        line.pop_back();
    size_t start = 0;
    while (start < line.size() && (line[start] == ' ' || line[start] == '\t'))
        ++start;
    if (start >= line.size()) return false;
    line = line.substr(start);

    auto eq = line.find('=');
    if (eq == std::string::npos) return false;
    std::string pkg = line.substr(0, eq);
    std::string rest = line.substr(eq + 1);
    while (!pkg.empty() && (pkg.back() == ' ' || pkg.back() == '\t'))
        pkg.pop_back();
    if (pkg.empty()) return false;

    std::string renderer = rest;
    bool enabled = true;
    auto colon = rest.find(':');
    if (colon != std::string::npos) {
        renderer = rest.substr(0, colon);
        std::string flag = rest.substr(colon + 1);
        if (flag == "0" || flag == "false" || flag == "no" || flag == "off")
            enabled = false;
    }
    while (!renderer.empty() && (renderer.front() == ' ' || renderer.front() == '\t'))
        renderer.erase(renderer.begin());
    while (!renderer.empty() && (renderer.back() == ' ' || renderer.back() == '\t'))
        renderer.pop_back();
    if (!enabled || !validRenderer(renderer)) return false;
    *pkgOut = pkg;
    *rendererOut = renderer;
    return true;
}

std::string packageFromDataDir(const char *dir) {
    if (!dir || !*dir) return {};
    std::string s(dir);
    while (!s.empty() && s.back() == '/') s.pop_back();
    auto pos = s.rfind('/');
    if (pos == std::string::npos) return {};
    return s.substr(pos + 1);
}

std::string packageFromNiceName(const char *name) {
    if (!name || !*name) return {};
    std::string s(name);
    auto colon = s.find(':');
    if (colon != std::string::npos) s.resize(colon);
    return s;
}

std::string jstringToUtf8(JNIEnv *env, jstring js) {
    if (!env || !js) return {};
    const char *utf = env->GetStringUTFChars(js, nullptr);
    if (!utf) return {};
    std::string out(utf);
    env->ReleaseStringUTFChars(js, utf);
    return out;
}


/* ── COW property patching ───────────────────────────────────────────── */

constexpr const char *kPropAreaPrefix = "/dev/__properties__/";
constexpr size_t kPropInfoSerialSize = sizeof(uint32_t); /* atomic serial */
constexpr size_t kPropInfoValueOff = kPropInfoSerialSize;
constexpr size_t kPropInfoNameOff = kPropInfoSerialSize + PROP_VALUE_MAX;
constexpr int kMapsLineFields = 4;           /* start, end, offset, path */
constexpr uint32_t kSerialLongFlag = 1u << 16;

struct AreaMap {
    uintptr_t start = 0, end = 0;
    uint64_t off = 0;
    std::string path;
};

static bool findAreaMap(uintptr_t addr, AreaMap *out) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) {
        log_msg("COW: cannot open /proc/self/maps errno=%d", errno);
        return false;
    }
    char line[1024];
    bool found = false;
    while (fgets(line, sizeof(line), f)) {
        unsigned long long s = 0, e = 0, off = 0;
        char path[512] = {};
        if (sscanf(line, "%llx-%llx %*s %llx %*x:%*x %*s %511s", &s, &e, &off,
                   path) < kMapsLineFields)
            continue;
        if (addr < s || addr >= e) continue;
        if (strncmp(path, kPropAreaPrefix, strlen(kPropAreaPrefix)) != 0)
            break;
        out->start = (uintptr_t)s;
        out->end = (uintptr_t)e;
        out->off = off;
        out->path = path;
        found = true;
        break;
    }
    fclose(f);
    return found;
}

using prop_find_fn = const void *(*)(const char *);
using prop_get_fn = int (*)(const char *, char *);

/* Returns 1 = patched & verified, 0 = property not present, -1 = failure. */
static int cowPatchProp(const char *name, const char *value) {
    auto find = (prop_find_fn)dlsym(RTLD_DEFAULT, "__system_property_find");
    auto get = (prop_get_fn)dlsym(RTLD_DEFAULT, "__system_property_get");
    if (!find || !get) {
        log_msg("COW: dlsym failed find=%p get=%p", (void *)find, (void *)get);
        return -1;
    }

    const void *pi = find(name);
    if (!pi) {
        log_msg("COW: %s not present in property area (nothing to patch)", name);
        return 0;
    }

    char *base = (char *)pi;
    const char *pname = base + kPropInfoNameOff;
    if (strcmp(pname, name) != 0) {
        /* prop_info layout differs from what we assume: refuse to write. */
        log_msg("COW: layout check failed for %s (name at +%zu='%.40s')", name,
                kPropInfoNameOff, pname);
        return -1;
    }

    uint32_t serial;
    memcpy(&serial, base, sizeof(serial));
    if (serial & kSerialLongFlag) {
        log_msg("COW: %s is a long property, not supported", name);
        return -1;
    }
    size_t vlen = strlen(value);
    if (vlen >= PROP_VALUE_MAX) {
        log_msg("COW: value too long for %s", name);
        return -1;
    }

    AreaMap area;
    if (!findAreaMap((uintptr_t)pi, &area)) {
        log_msg("COW: prop_info %p is not inside /dev/__properties__", pi);
        return -1;
    }

    const uintptr_t pageSize = (uintptr_t)sysconf(_SC_PAGESIZE);
    uintptr_t lo = (uintptr_t)pi & ~(pageSize - 1);
    const uintptr_t nameEnd =
        (uintptr_t)pi + kPropInfoNameOff + strlen(name) + 1;
    uintptr_t hi = (nameEnd + pageSize - 1) & ~(pageSize - 1);
    if (lo < area.start) lo = area.start;
    if (hi > area.end) hi = area.end;
    if (hi <= lo) return -1;

    int fd = open(area.path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        log_msg("COW: open(%s) failed errno=%d", area.path.c_str(), errno);
        return -1;
    }
    void *r = mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_FIXED, fd,
                   (off_t)(area.off + (lo - area.start)));
    int merr = errno;
    close(fd);
    if (r == MAP_FAILED) {
        log_msg("COW: private remap of %s [%#lx,%#lx) failed errno=%d",
                area.path.c_str(), (unsigned long)lo, (unsigned long)hi, merr);
        return -1;
    }

    /* value (NUL padded) then serial: length in the top byte, counter +2
     * (keeps the "dirty" bit clear) so serial-keyed caches re-read. */
    char *vdst = base + kPropInfoValueOff;
    memset(vdst, 0, PROP_VALUE_MAX);
    memcpy(vdst, value, vlen);
    uint32_t ns = ((uint32_t)vlen << 24) | (((serial & 0x00ffffffu) + 2) & 0x00ffffffu);
    memcpy(base, &ns, sizeof(ns));

    /* Back to read-only, like a stock property page. */
    mprotect((void *)lo, hi - lo, PROT_READ);

    char check[PROP_VALUE_MAX] = {};
    get(name, check);
    bool ok = strcmp(check, value) == 0;
    log_msg("COW: %s=%s in %s page[%#lx,%#lx) readback=%s %s", name, value,
            area.path.c_str(), (unsigned long)lo, (unsigned long)hi, check,
            ok ? "OK" : "MISMATCH");
    return ok ? 1 : -1;
}

/* Patch everything that decides the HWUI pipeline for this process. */
static bool applyRendererOverride() {
    const bool vk = strcmp(g_override, "skiavk") == 0;
    int r1 = cowPatchProp(kPropHwui, g_override);
    int r2 = cowPatchProp(kPropVulkan, vk ? "true" : "false");
    /* ro.hwui.use_vulkan may legitimately not exist; the renderer prop is the
     * one that matters. */
    return r1 == 1 && r2 != -1;
}

/* ── Root companion: lookup only (no global property writes) ──────────
 *
 * The companion process is long-lived, so targets.conf is parsed once and kept
 * in memory.  Per app launch the cost is two stat() calls; the files are
 * re-read only when mtime/size changes.  Non-target apps produce no log lines.
 */

struct ConfState {
    bool present = false;
    time_t sec = 0;
    long nsec = 0;
    off_t size = 0;
};

static pthread_mutex_t g_conf_mu = PTHREAD_MUTEX_INITIALIZER; //-V616 (macro, value 0)
static ConfState g_conf_state[sizeof(kTargetsPaths) / sizeof(kTargetsPaths[0])];
static std::map<std::string, std::string> g_targets;
static bool g_conf_any = false;
static bool g_conf_loaded = false;

/* Caller holds g_conf_mu. */
static void refreshTargetsLocked(const char *const *paths, size_t n) {
    ConfState cur[sizeof(g_conf_state) / sizeof(g_conf_state[0])];
    bool changed = !g_conf_loaded;
    for (size_t i = 0; i < n; ++i) {
        struct stat st {};
        if (stat(paths[i], &st) == 0) {
            cur[i].present = true;
            cur[i].sec = st.st_mtim.tv_sec;
            cur[i].nsec = st.st_mtim.tv_nsec;
            cur[i].size = st.st_size;
        }
        if (cur[i].present != g_conf_state[i].present ||
            cur[i].sec != g_conf_state[i].sec ||
            cur[i].nsec != g_conf_state[i].nsec ||
            cur[i].size != g_conf_state[i].size)
            changed = true;
    }
    if (!changed) return;

    g_targets.clear();
    g_conf_any = false;
    for (size_t i = 0; i < n; ++i) {
        g_conf_state[i] = cur[i];
        if (!cur[i].present) continue;
        std::ifstream in(paths[i]);
        if (!in) continue;
        g_conf_any = true;
        std::string line, pkg, renderer;
        while (std::getline(in, line))
            if (parseTargetLine(line, &pkg, &renderer))
                g_targets.emplace(pkg, renderer); /* first file wins */
    }
    g_conf_loaded = true;
    log_msg("companion: targets (re)loaded: %zu active entr%s, conf %s",
            g_targets.size(), g_targets.size() == 1 ? "y" : "ies",
            g_conf_any ? "ok" : "MISSING");
}

/* 1 = found, 0 = not a target, -2 = no readable conf */
static int lookupTarget(const std::string &pkg, std::string *renderer,
                        const char *const *paths, size_t n) {
    pthread_mutex_lock(&g_conf_mu);
    refreshTargetsLocked(paths, n);
    int rc;
    auto it = g_targets.find(pkg);
    if (it != g_targets.end()) {
        *renderer = it->second;
        rc = 1;
    } else {
        rc = g_conf_any ? 0 : -2;
    }
    pthread_mutex_unlock(&g_conf_mu);
    return rc;
}

void companion_handler(int client) {
    uint8_t op = 0;
    if (TEMP_FAILURE_RETRY(read(client, &op, 1)) != 1) {
        int rc = -1;
        TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
        return;
    }
    if (op != OP_LOOKUP) {
        int rc = -1;
        TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
        return;
    }

    uint16_t len = 0;
    if (TEMP_FAILURE_RETRY(read(client, &len, sizeof(len))) !=
            (ssize_t)sizeof(len) ||
        len == 0 || len > 255) {
        int rc = -1;
        TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
        return;
    }

    std::string pkg(len, '\0');
    size_t got = 0;
    while (got < len) {
        ssize_t n = TEMP_FAILURE_RETRY(read(client, &pkg[got], len - got));
        if (n <= 0) break;
        got += (size_t)n;
    }
    if (got != len) {
        int rc = -1;
        TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
        return;
    }

    std::string renderer;
    int rc = lookupTarget(pkg, &renderer, kTargetsPaths,
                          sizeof(kTargetsPaths) / sizeof(kTargetsPaths[0]));
    if (rc != 1) {
        TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
        return;
    }

    log_msg("companion: HIT %s -> %s", pkg.c_str(), renderer.c_str());
    TEMP_FAILURE_RETRY(write(client, &rc, sizeof(rc)));
    char out[PROP_VALUE_MAX] = {};
    strncpy(out, renderer.c_str(), PROP_VALUE_MAX - 1);
    TEMP_FAILURE_RETRY(write(client, out, PROP_VALUE_MAX));
}

/* status: 1=found (renderer filled), 0=no target, -2=conf fail, -1=error */
int companionLookup(zygisk::Api *api, const std::string &pkg,
                    std::string *outRenderer) {
    if (!api || !outRenderer) return -1;
    int fd = api->connectCompanion();
    if (fd < 0) {
        log_msg("companion: connect FAILED for %s (fd=%d)", pkg.c_str(), fd);
        return -1;
    }

    uint8_t op = OP_LOOKUP;
    uint16_t len = (uint16_t)pkg.size();
    bool ok = true;
    if (TEMP_FAILURE_RETRY(write(fd, &op, 1)) != 1) ok = false;
    if (ok && TEMP_FAILURE_RETRY(write(fd, &len, sizeof(len))) !=
                  (ssize_t)sizeof(len))
        ok = false;
    if (ok && TEMP_FAILURE_RETRY(write(fd, pkg.data(), pkg.size())) !=
                  (ssize_t)pkg.size())
        ok = false;

    int rc = -1;
    if (ok) {
        ssize_t nr = TEMP_FAILURE_RETRY(read(fd, &rc, sizeof(rc)));
        if (nr != (ssize_t)sizeof(rc)) rc = -1;
    }
    if (rc == 1) {
        char buf[PROP_VALUE_MAX] = {};
        size_t got = 0;
        while (got < PROP_VALUE_MAX) {
            ssize_t n =
                TEMP_FAILURE_RETRY(read(fd, buf + got, PROP_VALUE_MAX - got));
            if (n <= 0) break;
            got += (size_t)n;
        }
        buf[PROP_VALUE_MAX - 1] = '\0';
        *outRenderer = buf;
        if (!validRenderer(*outRenderer)) rc = -1;
    }
    close(fd);
    return rc;
}

} // namespace

class RenderSwitcherModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        if (!env || !args) return;

        /* Child zygotes and root-granted processes are skipped.  There is no
         * uid range filter: which packages are affected is decided only by
         * targets.conf (package name -> renderer). */
        bool childZygote = args->is_child_zygote && *args->is_child_zygote;
        bool isRoot = (api->getFlags() & zygisk::StateFlag::PROCESS_GRANTED_ROOT) != 0;
        if (childZygote || isRoot) {
            api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        std::string pkg;
        if (args->app_data_dir) {
            auto dir = jstringToUtf8(env, args->app_data_dir);
            pkg = packageFromDataDir(dir.c_str());
        }
        if (pkg.empty() && args->nice_name) {
            auto nice = jstringToUtf8(env, args->nice_name);
            pkg = packageFromNiceName(nice.c_str());
        }
        if (pkg.empty() || !validPackage(pkg)) {
            api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        std::string renderer;
        int crc = companionLookup(api, pkg, &renderer);
        if (crc == 0) { /* not a target: silent, no per-launch log noise */
            api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }
        if (crc != 1 || renderer.empty()) {
            log_msg("skip %s uid=%d (lookup rc=%d) — conf/companion fail",
                    pkg.c_str(), args->uid, crc);
            api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        strncpy(g_override, renderer.c_str(), PROP_VALUE_MAX - 1);
        g_override[PROP_VALUE_MAX - 1] = '\0';
        g_has_override = true;
        g_pkg = pkg;
        log_msg("target %s -> %s uid=%d pid=%d (COW patch in post)", pkg.c_str(),
                renderer.c_str(), args->uid, (int)getpid());
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        (void)args;
        if (!g_has_override) return;
        /* After specialize the process already has its final SELinux domain;
         * whatever it can map, it can patch.  HWUI initialises much later. */
        bool ok = applyRendererOverride();
        if (ok)
            log_msg("ENFORCEMENT ACTIVE %s -> %s (COW) pid=%d", g_pkg.c_str(),
                    g_override, (int)getpid());
        else
            log_msg("ENFORCEMENT FAILED %s -> %s (COW) pid=%d", g_pkg.c_str(),
                    g_override, (int)getpid());
        /* No hooks remain, nothing needs to stay resident. */
        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *args) override {
        (void)args;
        if (api) api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
};

REGISTER_ZYGISK_MODULE(RenderSwitcherModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
