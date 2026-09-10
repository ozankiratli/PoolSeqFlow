#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and print everything it wrote.

    on_a_tty.py <answer> <command> [args...]

The command sees a terminal, so a branch guarded by `[ -t 0 ]` is reachable; <answer> is
written to it followed by a newline. Exits with the command's own status.

This process never reads its own stdin. `script(1)` does, and inside `run_tests.sh` that
drains the loop feeding it test names: the run then ends after the first case that used a
terminal, reporting only the cases before it and no error at all.
"""

import os
import pty
import select
import sys

READ_TIMEOUT_SECONDS = 30


def run(answer, argv):
    """Spawn argv on a pty, send answer, and return (output, exit status)."""
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    os.write(fd, (answer + "\n").encode())

    chunks = []
    while True:
        readable, _, _ = select.select([fd], [], [], READ_TIMEOUT_SECONDS)
        if not readable:
            break
        try:
            data = os.read(fd, 4096)
        except OSError:
            # The child closed the pty, which is how a normal exit looks from here.
            break
        if not data:
            break
        chunks.append(data)

    os.close(fd)
    _, status = os.waitpid(pid, 0)
    return b"".join(chunks).decode("utf-8", "replace"), os.waitstatus_to_exitcode(status)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: on_a_tty.py <answer> <command> [args...]\n")
        return 2
    output, status = run(sys.argv[1], sys.argv[2:])
    sys.stdout.write(output)
    return status


if __name__ == "__main__":
    sys.exit(main())
