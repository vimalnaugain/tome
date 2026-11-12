/*
 * tomecore: the few system calls Tome needs that plain Lua cannot make.
 *
 * Tome ships a statically linked LuaJIT on Kindle (no dynamic loader, no
 * dlsym), so instead of ffi.C we expose a tiny, explicit C module:
 * evdev input, poll(), framebuffer geometry, a monotonic clock and kill().
 *
 * Built two ways:
 *   - linked into the Kindle LuaJIT binary (tools/build_kindle.sh), registered
 *     in package.preload by native/tome_main.c;
 *   - as a shared module `tomecore.so` for desktop development (make -C native).
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>

#include "lauxlib.h"
#include "lua.h"

#define BITS_PER_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_PER_LONG - 1) / BITS_PER_LONG)
#define TEST_BIT(bit, array) ((array[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1UL)

static int push_errno(lua_State *L) {
    int e = errno;
    lua_pushnil(L);
    lua_pushstring(L, strerror(e));
    lua_pushinteger(L, e);
    return 3;
}

/* open(path, writable, nonblock) -> fd | nil, err */
static int l_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int flags = lua_toboolean(L, 2) ? O_RDWR : O_RDONLY;
    if (lua_toboolean(L, 3)) flags |= O_NONBLOCK;
    flags |= O_CLOEXEC;
    int fd = open(path, flags);
    if (fd < 0) return push_errno(L);
    lua_pushinteger(L, fd);
    return 1;
}

static int l_close(lua_State *L) {
    close((int)luaL_checkinteger(L, 1));
    return 0;
}

/* grab(fd, on) -> true | nil, err  (EVIOCGRAB keeps the Kindle UI from seeing our taps) */
static int l_grab(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    int on = lua_toboolean(L, 2);
    if (ioctl(fd, EVIOCGRAB, on) < 0) return push_errno(L);
    lua_pushboolean(L, 1);
    return 1;
}

/* name(fd) -> device name */
static int l_name(lua_State *L) {
    char buf[256] = {0};
    if (ioctl((int)luaL_checkinteger(L, 1), EVIOCGNAME(sizeof(buf) - 1), buf) < 0) return push_errno(L);
    lua_pushstring(L, buf);
    return 1;
}

/* caps(fd) -> { ev = {type=true...}, abs = {code=true...}, keys = n } */
static int l_caps(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    unsigned long evbits[NLONGS(EV_CNT)];
    unsigned long absbits[NLONGS(ABS_CNT)];
    unsigned long keybits[NLONGS(KEY_CNT)];
    memset(evbits, 0, sizeof(evbits));
    memset(absbits, 0, sizeof(absbits));
    memset(keybits, 0, sizeof(keybits));
    if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0) return push_errno(L);
    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits);
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits);

    lua_createtable(L, 0, 3);
    lua_createtable(L, 0, 4);
    for (int i = 0; i < EV_CNT; i++)
        if (TEST_BIT(i, evbits)) { lua_pushboolean(L, 1); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "ev");
    lua_createtable(L, 0, 8);
    for (int i = 0; i < ABS_CNT; i++)
        if (TEST_BIT(i, absbits)) { lua_pushboolean(L, 1); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "abs");
    lua_createtable(L, 0, 8);
    int nkeys = 0;
    for (int i = 0; i < KEY_CNT; i++)
        if (TEST_BIT(i, keybits)) { lua_pushboolean(L, 1); lua_rawseti(L, -2, i); nkeys++; }
    lua_setfield(L, -2, "key");
    lua_pushinteger(L, nkeys);
    lua_setfield(L, -2, "nkeys");
    return 1;
}

/* absinfo(fd, code) -> min, max */
static int l_absinfo(lua_State *L) {
    struct input_absinfo info;
    if (ioctl((int)luaL_checkinteger(L, 1), EVIOCGABS((int)luaL_checkinteger(L, 2)), &info) < 0)
        return push_errno(L);
    lua_pushinteger(L, info.minimum);
    lua_pushinteger(L, info.maximum);
    return 2;
}

/* tcp_listen(ip, port) -> fd | nil, err   (non-blocking, SO_REUSEADDR) */
static int l_tcp_listen(lua_State *L) {
    const char *ip = luaL_checkstring(L, 1);
    int port = (int)luaL_checkinteger(L, 2);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        lua_pushnil(L); lua_pushstring(L, "bad IP address"); return 2;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return push_errno(L);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 4) < 0) {
        int e = errno; close(fd); errno = e; return push_errno(L);
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    lua_pushinteger(L, fd);
    return 1;
}

/* accept(fd) -> client_fd, peer_ip | nil (nothing waiting) */
static int l_accept(lua_State *L) {
    struct sockaddr_in peer;
    socklen_t len = sizeof(peer);
    int c = accept((int)luaL_checkinteger(L, 1), (struct sockaddr *)&peer, &len);
    if (c < 0) { lua_pushnil(L); return 1; }
    fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK);
    fcntl(c, F_SETFD, FD_CLOEXEC);
    char buf[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &peer.sin_addr, buf, sizeof(buf));
    lua_pushinteger(L, c);
    lua_pushstring(L, buf);
    return 2;
}

/* write(fd, data) -> bytes written | nil, err */
static int l_write(lua_State *L) {
    size_t len;
    const char *data = luaL_checklstring(L, 2, &len);
    ssize_t w = send((int)luaL_checkinteger(L, 1), data, len, MSG_NOSIGNAL);
    if (w < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) { lua_pushinteger(L, 0); return 1; }
        return push_errno(L);
    }
    lua_pushinteger(L, (lua_Integer)w);
    return 1;
}

/* stat(path) -> size, mtime, is_dir | nil, err */
static int l_stat(lua_State *L) {
    struct stat st;
    if (stat(luaL_checkstring(L, 1), &st) < 0) return push_errno(L);
    lua_pushnumber(L, (lua_Number)st.st_size);
    lua_pushnumber(L, (lua_Number)st.st_mtime);
    lua_pushboolean(L, S_ISDIR(st.st_mode));
    return 3;
}

/* read(fd, max) -> string ("" if nothing available) | nil, err */
static int l_read(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    size_t max = (size_t)luaL_optinteger(L, 2, 4096);
    char buf[4096];
    if (max > sizeof(buf)) max = sizeof(buf);
    ssize_t r = read(fd, buf, max);
    if (r < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) { lua_pushliteral(L, ""); return 1; }
        return push_errno(L);
    }
    lua_pushlstring(L, buf, (size_t)r);
    return 1;
}

/* read_events(fd) -> { {type, code, value}, ... }  (drains a non-blocking fd) */
static int l_read_events(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    struct input_event ev[64];
    int n = 0;
    lua_newtable(L);
    for (;;) {
        ssize_t r = read(fd, ev, sizeof(ev));
        if (r <= 0) break;
        int count = (int)(r / sizeof(struct input_event));
        for (int i = 0; i < count; i++) {
            lua_createtable(L, 3, 0);
            lua_pushinteger(L, ev[i].type);  lua_rawseti(L, -2, 1);
            lua_pushinteger(L, ev[i].code);  lua_rawseti(L, -2, 2);
            lua_pushinteger(L, ev[i].value); lua_rawseti(L, -2, 3);
            lua_rawseti(L, -2, ++n);
        }
        if (count < 64) break;
    }
    return 1;
}

/* poll({fd, ...}, timeout_ms) -> { fd = true, ... } */
static int l_poll(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int timeout = (int)luaL_optinteger(L, 2, -1);
    struct pollfd pfds[32];
    int n = 0;
    int len = (int)lua_objlen(L, 1);
    for (int i = 1; i <= len && n < 32; i++) {
        lua_rawgeti(L, 1, i);
        pfds[n].fd = (int)lua_tointeger(L, -1);
        pfds[n].events = POLLIN;
        pfds[n].revents = 0;
        n++;
        lua_pop(L, 1);
    }
    int r;
    do { r = poll(pfds, n, timeout); } while (r < 0 && errno == EINTR);
    lua_newtable(L);
    for (int i = 0; r > 0 && i < n; i++)
        if (pfds[i].revents & POLLIN) { lua_pushboolean(L, 1); lua_rawseti(L, -2, pfds[i].fd); }
    return 1;
}

/* fbinfo(path) -> { xres, yres, bpp, line_length, rotate, grayscale } */
static int l_fbinfo(lua_State *L) {
    const char *path = luaL_optstring(L, 1, "/dev/fb0");
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return push_errno(L);
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &v) < 0 || ioctl(fd, FBIOGET_FSCREENINFO, &f) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return push_errno(L);
    }
    close(fd);
    lua_createtable(L, 0, 6);
    lua_pushinteger(L, v.xres); lua_setfield(L, -2, "xres");
    lua_pushinteger(L, v.yres); lua_setfield(L, -2, "yres");
    lua_pushinteger(L, v.bits_per_pixel); lua_setfield(L, -2, "bpp");
    lua_pushinteger(L, f.line_length); lua_setfield(L, -2, "line_length");
    lua_pushinteger(L, v.rotate); lua_setfield(L, -2, "rotate");
    lua_pushinteger(L, v.grayscale); lua_setfield(L, -2, "grayscale");
    return 1;
}

static int l_monotonic_ms(lua_State *L) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    lua_pushnumber(L, (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6);
    return 1;
}

static int l_sleep_ms(lua_State *L) {
    lua_Number ms = luaL_checknumber(L, 1);
    struct timespec ts = { (time_t)(ms / 1000), (long)((long long)ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
    return 0;
}

/* kill(pid, sig) -> true | nil, err */
static int l_kill(lua_State *L) {
    if (kill((pid_t)luaL_checkinteger(L, 1), (int)luaL_optinteger(L, 2, SIGTERM)) < 0) return push_errno(L);
    lua_pushboolean(L, 1);
    return 1;
}

static const luaL_Reg funcs[] = {
    {"open", l_open},
    {"close", l_close},
    {"grab", l_grab},
    {"name", l_name},
    {"caps", l_caps},
    {"absinfo", l_absinfo},
    {"read_events", l_read_events},
    {"read", l_read},
    {"stat", l_stat},
    {"tcp_listen", l_tcp_listen},
    {"accept", l_accept},
    {"write", l_write},
    {"poll", l_poll},
    {"fbinfo", l_fbinfo},
    {"monotonic_ms", l_monotonic_ms},
    {"sleep_ms", l_sleep_ms},
    {"kill", l_kill},
    {NULL, NULL},
};

int luaopen_tomecore(lua_State *L) {
    /* A phone closing the setup page early must not kill Tome. */
    signal(SIGPIPE, SIG_IGN);
    lua_newtable(L);
    luaL_register(L, NULL, funcs);
    /* Constants the Lua side needs. */
    lua_pushinteger(L, EV_SYN); lua_setfield(L, -2, "EV_SYN");
    lua_pushinteger(L, EV_KEY); lua_setfield(L, -2, "EV_KEY");
    lua_pushinteger(L, EV_ABS); lua_setfield(L, -2, "EV_ABS");
    lua_pushinteger(L, SYN_REPORT); lua_setfield(L, -2, "SYN_REPORT");
    lua_pushinteger(L, ABS_X); lua_setfield(L, -2, "ABS_X");
    lua_pushinteger(L, ABS_Y); lua_setfield(L, -2, "ABS_Y");
    lua_pushinteger(L, ABS_MT_SLOT); lua_setfield(L, -2, "ABS_MT_SLOT");
    lua_pushinteger(L, ABS_MT_POSITION_X); lua_setfield(L, -2, "ABS_MT_POSITION_X");
    lua_pushinteger(L, ABS_MT_POSITION_Y); lua_setfield(L, -2, "ABS_MT_POSITION_Y");
    lua_pushinteger(L, ABS_MT_TRACKING_ID); lua_setfield(L, -2, "ABS_MT_TRACKING_ID");
    lua_pushinteger(L, BTN_TOUCH); lua_setfield(L, -2, "BTN_TOUCH");
    lua_pushinteger(L, SIGTERM); lua_setfield(L, -2, "SIGTERM");
    lua_pushinteger(L, SIGKILL); lua_setfield(L, -2, "SIGKILL");
    return 1;
}
