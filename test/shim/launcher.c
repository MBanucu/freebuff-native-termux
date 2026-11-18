/*
 * Test fixture for shim-test.sh: a process that only starts children, so the
 * shim's execve and posix_spawn hooks can be exercised without freebuff.
 *
 *   launcher PROG ARGS...          execve(PROG, ...)
 *   launcher --spawn PROG ARGS...  posix_spawn(PROG, ...), wait, same exit code
 */

#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s [--spawn] prog args...\n", argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "--spawn") == 0) {
        pid_t pid;
        int status;

        if (argc < 4) return 2;
        if (posix_spawn(&pid, argv[2], NULL, NULL, &argv[2], environ) != 0) {
            perror("posix_spawn");
            return 111;
        }
        if (waitpid(pid, &status, 0) < 0) return 112;
        return WIFEXITED(status) ? WEXITSTATUS(status) : 113;
    }

    execve(argv[1], &argv[1], environ);
    perror("execve");
    return 111;
}
