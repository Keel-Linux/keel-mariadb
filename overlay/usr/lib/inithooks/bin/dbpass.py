#!/usr/bin/python3
"""Ask for the database values that the inithooks conf did not provide.

Called by firstboot.d/35mysqlpass only when a terminal is attached and a
value is absent; prints one KEY=value line per requested name on stdout so
the hook keeps the decisions and this file keeps the dialogs. On a headless
first boot the hook fails instead of calling this, because the value it
needs is declared: secrets.db_password of the instance description.

Syntax: dbpass.py NAME [NAME ...]      NAME is DB_PASS
"""

import sys

from libinithooks.dialog_wrapper import Dialog

TITLE = "Keel - First boot configuration"


def ask(name: str, dialog: Dialog) -> str:
    if name == "DB_PASS":
        return dialog.get_password(
            "MariaDB password",
            "Enter the password for the MariaDB administrative account.")
    raise SystemExit(f"dbpass.py: unknown value name {name!r}")


def main(names: list[str]) -> int:
    if not names:
        print(__doc__, file=sys.stderr)
        return 1
    dialog = Dialog(TITLE)
    for name in names:
        print(f"{name}={ask(name, dialog)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
