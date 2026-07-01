/*
 * claude-resolvfix.so  —  LD_PRELOAD DNS shim for native glibc CLIs on Termux.
 *
 * glibc's resolver (and Bun's, via libc) opens /etc/resolv.conf for DNS, but
 * Termux's /etc is a read-only symlink to /system/etc, so that file cannot exist
 * natively. Instead of proot, this shim intercepts open()/fopen() of
 * /etc/resolv.conf and redirects it to Termux's copy ($PREFIX/etc/resolv.conf).
 *
 * Shared across the *-termux-native installers (Claude, OpenCode). Redirect
 * target overridable at runtime via env CLAUDE_RESOLV_REDIRECT.
 */
#include <stdarg.h>        /* compiler builtin; no libc headers required */

extern void *dlsym(void *handle, const char *symbol);
extern char *getenv(const char *name);
extern int   strcmp(const char *a, const char *b);
extern int   unsetenv(const char *name);
#define RTLD_NEXT ((void *) -1L)
#define O_CREAT   0100        /* aarch64/Linux generic value */

typedef struct _IO_FILE FILE;

static const char *TARGET = "/etc/resolv.conf";
static const char *REDIR  = "/data/data/com.termux/files/usr/etc/resolv.conf";

static const char *target_path(void) {
    const char *e = getenv("CLAUDE_RESOLV_REDIRECT");
    return (e && *e) ? e : REDIR;
}
static const char *fix(const char *p) {
    return (p && strcmp(p, TARGET) == 0) ? target_path() : p;
}

/* Scrub loader env vars so bionic child tools don't try to load glibc. */
__attribute__((constructor))
static void scrub_loader_env(void) {
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");
}

FILE *fopen(const char *p, const char *m) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    return real(fix(p), m);
}
FILE *fopen64(const char *p, const char *m) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen64");
    return real(fix(p), m);
}
int open(const char *p, int flags, ...) {
    static int (*real)(const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "open");
    int mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, int); va_end(a); }
    return real(fix(p), flags, mode);
}
int open64(const char *p, int flags, ...) {
    static int (*real)(const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "open64");
    int mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, int); va_end(a); }
    return real(fix(p), flags, mode);
}
int openat(int dirfd, const char *p, int flags, ...) {
    static int (*real)(int, const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    int mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, int); va_end(a); }
    return real(dirfd, fix(p), flags, mode);
}
