/*
 * freebuff-native-spawn-shim.c
 *
 * Workaround for CodebuffAI/freebuff#1688.
 *
 * freebuff re-execs itself to run its "terminal command broker", using
 * `process.execPath` as the executable.  When the CLI is started through an ELF
 * interpreter (glibc-runner on Termux, `ld.so --library-path … freebuff`), the
 * kernel's main executable is the loader, so `process.execPath` is
 * `…/glibc/lib/ld-linux-aarch64.so.1`.  The broker then becomes
 *
 *     ld.so --terminal-command-broker
 *     ld.so: unrecognized option '--terminal-command-broker'
 *
 * which exits without writing its result file; the parent reports
 * "terminal command broker protocol response was missing" and no shell tool can
 * run.  The same `dirname(process.execPath)` assumption also breaks ripgrep
 * extraction (worked around separately with CODEBUFF_RG_PATH).
 *
 * This shim is loaded into the freebuff process with LD_PRELOAD.  It rewrites
 * that one exec into
 *
 *     ld.so --library-path <libdir> <binary> --terminal-command-broker
 *
 * and strips LD_PRELOAD from every child's environment, so bionic Termux
 * binaries (sh, git, rg, …) can start normally.  Nothing else is touched, and
 * the freebuff binary itself stays pristine.
 *
 * Configuration comes from the wrapper's environment:
 *   FREEBUFF_NATIVE_LOADER   absolute path of the glibc loader
 *   FREEBUFF_NATIVE_LIBDIR   directory passed to the loader as --library-path
 *   FREEBUFF_NATIVE_BINARY   absolute path of the pristine freebuff binary
 *   FREEBUFF_SHIM_LOG        optional file to append diagnostics to
 *   FREEBUFF_SHIM_TRACE      if set (and a log is configured), append every
 *                            exec path, which is how you confirm that the shim
 *                            is interposing the real freebuff process
 *
 * Built freestanding (no libc headers): Termux's compiler ships bionic headers
 * for the Android target, and the glibc-targeted build must not see them.  The
 * few declarations used here are all stable ABI.
 */

typedef __SIZE_TYPE__ size_t;
typedef long ssize_t;
typedef int pid_t;

#define NULL ((void *)0)
#define ENOSYS 38
#define O_WRONLY 1
#define O_CREAT 0100
#define O_APPEND 02000

extern char **environ;
extern void *malloc(size_t);
extern void *dlsym(void *handle, const char *symbol);
extern char *getenv(const char *);
extern int open(const char *, int, ...);
extern ssize_t write(int, const void *, size_t);
extern int close(int);
extern int strcmp(const char *, const char *);
extern int strncmp(const char *, const char *, size_t);
extern size_t strlen(const char *);
extern char *strrchr(const char *, int);

#define RTLD_NEXT ((void *)-1L)

#define BROKER_FLAG "--terminal-command-broker"
#define ENV_LOADER "FREEBUFF_NATIVE_LOADER"
#define ENV_LIBDIR "FREEBUFF_NATIVE_LIBDIR"
#define ENV_BINARY "FREEBUFF_NATIVE_BINARY"
#define ENV_LOG "FREEBUFF_SHIM_LOG"
#define ENV_TRACE "FREEBUFF_SHIM_TRACE"

typedef int (*execve_fn)(const char *, char *const[], char *const[]);
typedef int (*posix_spawn_fn)(pid_t *, const char *, const void *,
                              const void *, char *const[], char *const[]);

static void shim_log(const char *what, const char *detail)
{
    const char *path = getenv(ENV_LOG);
    char line[512];
    size_t n;
    int fd;

    if (!path || !*path) return;

    n = 0;
    line[n++] = '[';
    while (*what && n < sizeof(line) - 4) line[n++] = *what++;
    line[n++] = ']';
    line[n++] = ' ';
    if (detail) {
        while (*detail && n < sizeof(line) - 2) line[n++] = *detail++;
    }
    line[n++] = '\n';

    fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    (void)write(fd, line, n);
    close(fd);
}

static int has_broker_flag(char *const argv[])
{
    size_t i;

    if (!argv) return 0;
    for (i = 1; argv[i]; i++) {
        if (strcmp(argv[i], BROKER_FLAG) == 0) return 1;
    }
    return 0;
}

static int is_loader(const char *path, const char *loader)
{
    const char *base;

    if (!path) return 0;
    if (loader && *loader && strcmp(path, loader) == 0) return 1;

    base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strncmp(base, "ld-linux", 8) == 0) return 1;
    if (strcmp(base, "ld.so") == 0) return 1;
    return 0;
}

/* Copy envp without LD_PRELOAD, which cannot be loaded by bionic children. */
static char **clean_env(char *const envp[])
{
    char *const *src = envp ? envp : environ;
    size_t count = 0;
    size_t i;
    size_t out = 0;
    char **copy;

    if (!src) return NULL;
    while (src[count]) count++;

    copy = (char **)malloc((count + 1) * sizeof(char *));
    if (!copy) return (char **)src;

    for (i = 0; i < count; i++) {
        if (strncmp(src[i], "LD_PRELOAD=", 11) == 0) continue;
        copy[out++] = src[i];
    }
    copy[out] = NULL;
    return copy;
}

/*
 * Build the loader invocation that actually runs the broker.  Returns NULL when
 * this exec must be left alone.
 */
static char **rewrite_argv(const char *path, char *const argv[],
                           const char *libdir, const char *binary)
{
    size_t argc = 0;
    size_t i;
    char **out;

    if (!libdir || !*libdir || !binary || !*binary) return NULL;
    if (!argv || !argv[0] || !has_broker_flag(argv)) return NULL;

    while (argv[argc]) argc++;

    /* path, --library-path, libdir, binary, original args (incl. NULL) */
    out = (char **)malloc((argc + 4) * sizeof(char *));
    if (!out) return NULL;

    out[0] = (char *)path;
    out[1] = (char *)"--library-path";
    out[2] = (char *)libdir;
    out[3] = (char *)binary;
    for (i = 1; i <= argc; i++) out[i + 3] = argv[i];
    return out;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static execve_fn real;
    char **nenv;
    char **nargv = NULL;
    int broker = 0;

    if (!real) real = (execve_fn)dlsym(RTLD_NEXT, "execve");
    if (!real) return -1;

    nenv = clean_env(envp);
    if (getenv(ENV_TRACE)) shim_log("exec", path);

    if (is_loader(path, getenv(ENV_LOADER)) && has_broker_flag(argv)) {
        broker = 1;
        nargv = rewrite_argv(path, argv, getenv(ENV_LIBDIR),
                             getenv(ENV_BINARY));
    }

    if (nargv) {
        shim_log("spawn-shim", "rewrote broker exec through the loader");
        return real(path, nargv, nenv);
    }
    if (broker)
        shim_log("spawn-shim", "broker exec left broken: missing config");
    return real(path, argv, nenv);
}

int posix_spawn(pid_t *pid, const char *path, const void *file_actions,
                const void *attrp, char *const argv[], char *const envp[])
{
    static posix_spawn_fn real;
    char **nenv;

    if (!real) real = (posix_spawn_fn)dlsym(RTLD_NEXT, "posix_spawn");
    if (!real) return ENOSYS;

    nenv = clean_env(envp);

    if (is_loader(path, getenv(ENV_LOADER)) && has_broker_flag(argv)) {
        char **nargv = rewrite_argv(path, argv, getenv(ENV_LIBDIR),
                                    getenv(ENV_BINARY));
        if (nargv) {
            shim_log("spawn-shim", "rewrote broker posix_spawn through the loader");
            return real(pid, path, file_actions, attrp, nargv, nenv);
        }
    }
    return real(pid, path, file_actions, attrp, argv, nenv);
}

int posix_spawnp(pid_t *pid, const char *file, const void *file_actions,
                 const void *attrp, char *const argv[], char *const envp[])
{
    static posix_spawn_fn real;
    char **nenv;

    if (!real) real = (posix_spawn_fn)dlsym(RTLD_NEXT, "posix_spawnp");
    if (!real) return ENOSYS;

    nenv = clean_env(envp);

    if (is_loader(file, getenv(ENV_LOADER)) && has_broker_flag(argv)) {
        char **nargv = rewrite_argv(file, argv, getenv(ENV_LIBDIR),
                                    getenv(ENV_BINARY));
        if (nargv) return real(pid, file, file_actions, attrp, nargv, nenv);
    }
    return real(pid, file, file_actions, attrp, argv, nenv);
}
