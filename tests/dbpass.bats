#!/usr/bin/env bats
# bin/dbpass.py draws its dialog on the terminal, not in the hook's pipe.
#
# firstboot.d/35mysqlpass reads the script's standard output for KEY=value,
# and dialog draws its screen on standard output. On 2026-09-30 a
# keel-wordpress first boot on Proxmox froze at the MariaDB password
# because the box was drawn into that pipe. These tests run the script as the
# hook does, output redirected, inside a real pseudo terminal (script(1)),
# with a stand-in for libinithooks whose dialog refuses to draw anywhere but
# a terminal.

setup() {
    here="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    DBPASS="$here/../overlay/usr/lib/inithooks/bin/dbpass.py"
    FAKE="$BATS_TEST_TMPDIR/lib"
    mkdir -p "$FAKE/libinithooks"
    : > "$FAKE/libinithooks/__init__.py"
    cat > "$FAKE/libinithooks/dialog_wrapper.py" << 'EOF'
import os


class Dialog:
    def __init__(self, title):
        self.title = title

    def get_password(self, title, text):
        # what dialog needs to be seen: a terminal on standard output
        if not os.isatty(1):
            raise SystemExit("dialog would draw into a pipe")
        return "typed-at-the-console"
EOF
    OUT="$BATS_TEST_TMPDIR/answers"
}

run_as_the_hook() {
    # stdin and /dev/tty are the pseudo terminal; stdout is a file, as the
    # hook's process substitution makes it a pipe
    script -qec "PYTHONPATH='$FAKE' python3 '$DBPASS' $* > '$OUT'" /dev/null
}

@test "the answer reaches the hook while the dialog draws on the terminal" {
    run run_as_the_hook DB_PASS
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "DB_PASS=typed-at-the-console" ]
}

@test "without any terminal it says so instead of a traceback" {
    # setsid: no controlling terminal, and standard input is not one either
    PYTHONPATH="$FAKE" run setsid -w python3 "$DBPASS" DB_PASS < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal to draw the dialog on"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "without a name it prints its usage and fails" {
    PYTHONPATH="$FAKE" run python3 "$DBPASS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Syntax: dbpass.py NAME"* ]]
}
