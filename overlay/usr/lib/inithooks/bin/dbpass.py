#!/usr/bin/python3
"""Ask for the database values that the inithooks conf did not provide.

Called by firstboot.d/35mysqlpass only when a terminal is attached and a
value is absent; prints one KEY=value line per requested name on stdout so
the hook keeps the decisions and this file keeps the dialogs. On a headless
first boot the hook fails instead of calling this, because the value it
needs is declared: secrets.db_password of the instance description.

Syntax: dbpass.py NAME [NAME ...]      NAME is DB_PASS
"""

import os
import sys

from libinithooks.dialog_wrapper import Dialog

TTY = "/dev/tty"

TITLE = "Keel - First boot configuration"


def ask(name: str, dialog: Dialog) -> str:
    if name == "DB_PASS":
        return dialog.get_password(
            "MariaDB password",
            "Enter the password for the MariaDB administrative account.")
    raise SystemExit(f"dbpass.py: unknown value name {name!r}")


def terminal_path(tty: str = TTY) -> str:
    """The terminal to draw on: the one the hook checked on standard input,
    else the controlling terminal"""
    try:
        return os.ttyname(sys.stdin.fileno())
    except OSError:
        return tty


def answers_out(tty: str = TTY):
    """The hook's pipe for the answers, with standard output on the terminal

    The hook reads this script's standard output, and dialog draws its
    screen on standard output: left there, the password box is drawn into
    the hook's pipe, and the console shows a frozen screen waiting for a
    password nobody can see (2026-09-30, keel-wordpress on Proxmox). So
    the pipe is kept on a new descriptor for the KEY=value lines, and
    standard output, which dialog inherits, becomes the terminal.
    """
    path = terminal_path(tty)
    try:
        terminal = os.open(path, os.O_WRONLY)
    except OSError as e:
        raise SystemExit(
            f"dbpass.py: no terminal to draw the dialog on ({path}:"
            f" {e.strerror}); declare secrets.db_password in the instance"
            " description instead")
    answers = os.fdopen(os.dup(sys.stdout.fileno()), "w")
    os.dup2(terminal, sys.stdout.fileno())
    os.close(terminal)
    return answers


def main(names: list[str]) -> int:
    if not names:
        print(__doc__, file=sys.stderr)
        return 1
    answers = answers_out()
    dialog = Dialog(TITLE)
    for name in names:
        print(f"{name}={ask(name, dialog)}", file=answers)
    answers.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
