// switchboard-holder: keeps Switchboard's terminals alive while the app restarts for an
// update, then gives them to the new copy of the app. Programs in the terminals keep
// running and never notice: their end of each terminal (the pty) stays open.
//
//   switchboard-holder <socket path> <count> [timeout seconds]
//
// The pty masters arrive as inherited file descriptors 3 .. 3+count-1. The new app
// connects to the socket (same user only) and sends "GET\n". The holder sends every fd
// with SCM_RIGHTS in 8-byte messages "F<start:3><n:3>\n", then "END....\n". The app
// answers "OK\n" and the holder exits. When no app takes them within the timeout, the
// holder exits too: closing the masters hangs the programs up, as a normal restart would.
//
// Built by install-sessions-app.sh into Switchboard.app/Contents/MacOS.
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define CHUNK 16

static int send_chunk(int c, int start, int n) {
  char data[9];
  snprintf(data, sizeof data, "F%03d%03d\n", start, n);
  struct iovec iov = {data, 8};
  char buf[CMSG_SPACE(sizeof(int) * CHUNK)];
  memset(buf, 0, sizeof buf);
  struct msghdr m = {0};
  m.msg_iov = &iov;
  m.msg_iovlen = 1;
  m.msg_control = buf;
  m.msg_controllen = CMSG_SPACE(sizeof(int) * n);
  struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
  cm->cmsg_level = SOL_SOCKET;
  cm->cmsg_type = SCM_RIGHTS;
  cm->cmsg_len = CMSG_LEN(sizeof(int) * n);
  int *fds = (int *)CMSG_DATA(cm);
  for (int k = 0; k < n; k++) fds[k] = 3 + start + k;
  return sendmsg(c, &m, 0) == 8 ? 0 : -1;
}

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  const char *path = argv[1];
  int count = atoi(argv[2]);
  int timeout = argc > 3 ? atoi(argv[3]) : 120;
  if (count < 0 || count > 999 || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 2;

  setsid();
  signal(SIGHUP, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);
  signal(SIGINT, SIG_IGN);

  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s < 0) return 3;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
  unlink(path);
  mode_t old = umask(077);
  int bound = bind(s, (struct sockaddr *)&addr, sizeof addr);
  umask(old);
  if (bound != 0 || listen(s, 2) != 0) return 3;

  time_t deadline = time(NULL) + timeout;
  for (;;) {
    long left = (long)(deadline - time(NULL));
    if (left <= 0) break;
    struct pollfd p = {s, POLLIN, 0};
    int r = poll(&p, 1, (int)(left * 1000));
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    int c = accept(s, NULL, NULL);
    if (c < 0) continue;
    uid_t euid;
    gid_t egid;
    if (getpeereid(c, &euid, &egid) != 0 || euid != getuid()) { close(c); continue; }
    char req[4];
    struct pollfd pc = {c, POLLIN, 0};
    if (poll(&pc, 1, 10000) <= 0 || read(c, req, 4) != 4 || memcmp(req, "GET\n", 4) != 0) { close(c); continue; }
    int ok = 1;
    for (int i = 0; i < count && ok; i += CHUNK) {
      if (send_chunk(c, i, count - i < CHUNK ? count - i : CHUNK) != 0) ok = 0;
    }
    if (ok && write(c, "END....\n", 8) == 8) {
      char ack[3];
      if (poll(&pc, 1, 30000) > 0 && read(c, ack, 3) == 3 && memcmp(ack, "OK\n", 3) == 0) {
        close(c);
        unlink(path);
        return 0;
      }
    }
    close(c);
  }
  unlink(path);
  return 1;
}
