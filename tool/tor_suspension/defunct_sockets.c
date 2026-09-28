// Defunct every socket a process owns, as iOS does to a suspended app.
//
// The fallback for integration_test/tor_suspension_probe.dart when the app
// sandbox refuses pid_shutdown_sockets on the app's own pid. Run as root:
// the kernel then skips its posix check, and this binary has no sandbox.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// xnu bsd/kern/syscalls.master and bsd/sys/proc.h.
#define SYS_PID_SHUTDOWN_SOCKETS 436
#define SHUTDOWN_SOCKET_LEVEL_DISCONNECT_ALL 0x2

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <pid>\n", argv[0]);
    return 2;
  }
  int pid = atoi(argv[1]);
  int rc = syscall(SYS_PID_SHUTDOWN_SOCKETS, pid,
                   SHUTDOWN_SOCKET_LEVEL_DISCONNECT_ALL);
  printf("pid_shutdown_sockets(%d): %s\n", pid, rc == 0 ? "ok" : strerror(errno));
  return rc == 0 ? 0 : 1;
}
