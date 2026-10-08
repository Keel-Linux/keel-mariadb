#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh: argument parsing, address
# discovery from lxc-info, waiting with a deadline, the secret files, the
# database, Webmin and module verdicts, and the diff verdict. Nothing here
# needs root, a network, a database or LXC: lxc-info is a stub first in
# PATH, the clock and sleep are functions.

bats_require_minimum_version 1.5.0

setup() {
    load lib/boot-test-lib.sh
    STUBS=$(mktemp -d)
    PATH=$STUBS:$PATH
}

teardown() {
    rm -rf "$STUBS"
}

stub_lxc_info() {
    # stub_lxc_info OUTPUT: lxc-info prints OUTPUT and records its arguments
    printf '#!/bin/bash\necho "$*" >> "%s/lxc-info.calls"\ncat <<"OUT"\n%s\nOUT\n' "$STUBS" "$1" > "$STUBS/lxc-info"
    chmod +x "$STUBS/lxc-info"
}

# argument parsing

@test "parse_args: the appliance alone takes every default" {
    bt_parse_args mariadb
    [ "$BT_APPLIANCE" = mariadb ]
    [ "$BT_TIMEOUT" = 900 ]
    [ "$BT_INTERVAL" = 5 ]
    [ "$BT_BRIDGE" = br0 ]
    [ "$BT_LAYERS_DIR" = /mnt/builds/layers ]
    [ "$BT_CACHE_DIR" = /var/cache/keel/layers ]
    [ "$BT_LXC_PATH" = /var/lib/lxc ]
    [ -z "$BT_SPEC" ]
    [ "$BT_KEEP" = 0 ]
    [ "$BT_NAME" = keel-mariadb-boot-test ]
    [ "$BT_ROOTFS" = /var/lib/lxc/keel-mariadb-boot-test/rootfs ]
}

@test "parse_args: every option is read" {
    bt_parse_args --timeout 60 --interval 2 --bridge lxcbr0 --layers-dir /l \
        --cache-dir /c --lxc-path /x --name lamp-run-7 --spec /s.yaml --keep lamp
    [ "$BT_APPLIANCE" = lamp ]
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = lxcbr0 ]
    [ "$BT_LAYERS_DIR" = /l ]
    [ "$BT_CACHE_DIR" = /c ]
    [ "$BT_LXC_PATH" = /x ]
    [ "$BT_SPEC" = /s.yaml ]
    [ "$BT_KEEP" = 1 ]
    [ "$BT_NAME" = lamp-run-7 ]
    [ "$BT_ROOTFS" = /x/lamp-run-7/rootfs ]
}

@test "parse_args: --name is checked as a container name" {
    run bt_parse_args mariadb --name "Run 7"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a container name"* ]]
    run bt_parse_args mariadb --name -lead
    [ "$status" -eq 1 ]
}

@test "is_container_name" {
    bt_is_container_name keel-mariadb-ci-36255612491-1
    bt_is_container_name 7
    run ! bt_is_container_name "keel core"
    run ! bt_is_container_name -x
    run ! bt_is_container_name ""
}

@test "parse_args: the appliance is required" {
    run bt_parse_args --keep
    [ "$status" -eq 1 ]
    [[ $output == *"APPLIANCE is required"* ]]
}

@test "parse_args: one appliance at a time" {
    run bt_parse_args mariadb lamp
    [ "$status" -eq 1 ]
    [[ $output == *"one appliance at a time"* ]]
}

@test "parse_args: the keel- prefix and upper case are rejected" {
    run bt_parse_args keel-mariadb
    [ "$status" -eq 1 ]
    [[ $output == *"not an appliance name"* ]]
    run bt_parse_args NodeBB
    [ "$status" -eq 1 ]
}

@test "parse_args: an unknown option fails" {
    run bt_parse_args mariadb --verbose
    [ "$status" -eq 1 ]
    [[ $output == *"unknown option --verbose"* ]]
}

@test "parse_args: timeout and interval must be positive integers" {
    run bt_parse_args mariadb --timeout 0
    [ "$status" -eq 1 ]
    [[ $output == *"--timeout needs a positive number"* ]]
    run bt_parse_args mariadb --interval abc
    [ "$status" -eq 1 ]
    run bt_parse_args mariadb --timeout
    [ "$status" -eq 1 ]
}

@test "parse_args: an option with a value refuses an empty one" {
    run bt_parse_args mariadb --bridge
    [ "$status" -eq 1 ]
    [[ $output == *"--bridge needs a value"* ]]
    run bt_parse_args mariadb --spec ""
    [ "$status" -eq 1 ]
}

@test "parse_args: --help prints the usage and returns 2" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    [[ $output == *"--keep"* ]]
    run bt_parse_args -h
    [ "$status" -eq 2 ]
}

@test "is_positive_int and is_appliance_name" {
    bt_is_positive_int 1
    bt_is_positive_int 900
    run ! bt_is_positive_int 0
    run ! bt_is_positive_int 07
    run ! bt_is_positive_int -5
    run ! bt_is_positive_int ""
    bt_is_appliance_name nginx-php-fastcgi
    run ! bt_is_appliance_name keel-core
    run ! bt_is_appliance_name 9core
    run ! bt_is_appliance_name ""
}

# address discovery

@test "is_global_ipv6: global and ULA yes, link local, loopback, multicast, IPv4 no" {
    bt_is_global_ipv6 2001:db8:1::10
    bt_is_global_ipv6 fd00:1::10
    bt_is_global_ipv6 2001:DB8::1
    run ! bt_is_global_ipv6 fe80::216:3eff:fe00:1
    run ! bt_is_global_ipv6 FEBF::1
    run ! bt_is_global_ipv6 ::1
    run ! bt_is_global_ipv6 ff02::1
    run ! bt_is_global_ipv6 192.0.2.10
    run ! bt_is_global_ipv6 ""
}

@test "global_ipv6: picks the first global address out of lxc-info output" {
    output=$(printf 'IP:             fe80::216:3eff:fe00:1\nIP:             192.0.2.10\nIP:             2001:db8:1::10\nIP:             2001:db8:1::11\n' | bt_global_ipv6)
    [ "$output" = 2001:db8:1::10 ]
}

@test "global_ipv6: ignores lines that are not addresses" {
    output=$(printf 'Name:           keel-mariadb-boot-test\nState:          RUNNING\nPID:            4242\nIP:             fd00::10\nLink:           veth0\n' | bt_global_ipv6)
    [ "$output" = fd00::10 ]
}

@test "global_ipv6: returns 1 while only link local or IPv4 addresses exist" {
    run bt_global_ipv6 <<< $'IP:             fe80::1\nIP:             192.0.2.10'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_global_ipv6 < /dev/null
    [ "$status" -eq 1 ]
}

@test "container_ipv6: calls lxc-info with the lxcpath and the name" {
    stub_lxc_info $'Name:           keel-mariadb-boot-test\nIP:             fe80::1\nIP:             2001:db8:1::10'
    output=$(bt_container_ipv6 keel-mariadb-boot-test /var/lib/lxc)
    [ "$output" = 2001:db8:1::10 ]
    [ "$(cat "$STUBS/lxc-info.calls")" = "-P /var/lib/lxc -n keel-mariadb-boot-test -i" ]
}

@test "container_ipv6: fails when lxc-info has no global address yet" {
    stub_lxc_info $'Name:           keel-mariadb-boot-test\nState:          RUNNING'
    run bt_container_ipv6 keel-mariadb-boot-test /var/lib/lxc
    [ "$status" -eq 1 ]
}

# timeouts

fake_clock() { echo "$FAKE_NOW"; }
fake_sleep() { FAKE_NOW=$(( FAKE_NOW + $1 )); echo "sleep $1" >> "$STUBS/sleeps"; }
succeed_on_third() { CALLS=$(( CALLS + 1 )); [ "$CALLS" -ge 3 ]; }
never() { return 1; }

@test "deadline_passed" {
    run ! bt_deadline_passed 100 30 129
    bt_deadline_passed 100 30 130
    bt_deadline_passed 100 30 500
}

@test "now: the default clock is epoch seconds and BT_CLOCK replaces it" {
    [[ $(bt_now) =~ ^[0-9]{10}$ ]]
    BT_CLOCK=fake_clock FAKE_NOW=42
    [ "$(bt_now)" = 42 ]
}

@test "wait_for: polls at the interval until the command succeeds" {
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000 CALLS=0
    bt_wait_for 60 5 "three calls" succeed_on_third
    [ "$CALLS" -eq 3 ]
    [ "$(cat "$STUBS/sleeps")" = $'sleep 5\nsleep 5' ]
}

@test "wait_for: gives up with a message once the timeout has passed" {
    # shellcheck disable=SC2034  # read by bt_now and bt_wait_for
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000
    run bt_wait_for 12 5 "something that never happens" never
    [ "$status" -eq 1 ]
    [[ $output == *"timeout after 12s waiting for something that never happens"* ]]
    [ "$(wc -l < "$STUBS/sleeps")" -eq 3 ]
}

# readiness and verdicts

@test "is_ssh_banner" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-7"
    run ! bt_is_ssh_banner "HTTP/1.1 400 Bad Request"
    run ! bt_is_ssh_banner ""
}

@test "firstboot_done_in: RUN_FIRSTBOOT=false in the rootfs copy of /etc/default/inithooks" {
    printf 'INITHOOKS_CONF=/etc/inithooks.conf\nRUN_FIRSTBOOT=false\n' > "$STUBS/done"
    printf 'RUN_FIRSTBOOT=true\n' > "$STUBS/pending"
    bt_firstboot_done_in "$STUBS/done"
    run ! bt_firstboot_done_in "$STUBS/pending"
    run ! bt_firstboot_done_in "$STUBS/missing"
}

@test "lxc_config: names the container, the rootfs and the bridge" {
    output=$(bt_lxc_config keel-mariadb-boot-test /var/lib/lxc/keel-mariadb-boot-test/rootfs br0)
    [[ $output == *"lxc.uts.name = keel-mariadb-boot-test"* ]]
    [[ $output == *"lxc.rootfs.path = dir:/var/lib/lxc/keel-mariadb-boot-test/rootfs"* ]]
    [[ $output == *"lxc.net.0.link = br0"* ]]
    [[ $output == *"lxc.net.0.type = veth"* ]]
}

@test "lxc_config: the apparmor pair a container running systemd needs" {
    output=$(bt_lxc_config keel-mariadb-boot-test /r/rootfs br0)
    [[ $output == *"lxc.apparmor.profile = generated"* ]]
    [[ $output == *"lxc.apparmor.allow_nesting = 1"* ]]
}

fake_rootfs() {
    # fake_rootfs [VALUE]: a scratch rootfs with an inithooks defaults file,
    # REDIRECT_OUTPUT set to VALUE (default false), printed on stdout
    local rootfs="$BATS_TEST_TMPDIR/rootfs-$RANDOM"
    mkdir -p "$rootfs/etc/default"
    cat > "$rootfs/$BT_INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=/etc/inithooks.conf
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=${1-false}
SUDOADMIN=false
DEF
    printf '%s\n' "$rootfs"
}

@test "mark_container: writes the marker the unit conditions and inspect read" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ -f "$rootfs/var/lib/turnkey-info/inithooks.service/lxc" ]
}

@test "mark_container: turns REDIRECT_OUTPUT on, so no hook blocks writing to tty1" {
    rootfs=$(fake_rootfs false)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    grep -q '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    # the rest of the file is left alone
    grep -q '^RUN_FIRSTBOOT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    grep -q '^SUDOADMIN=false$' "$rootfs/$BT_INITHOOKS_DEFAULT"
}

@test "mark_container: takes the first boot off tty1 with a systemd drop-in" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    dropin="$rootfs/$BT_INITHOOKS_DROPIN"
    [ -f "$dropin" ]
    grep -q '^\[Service\]$' "$dropin"
    grep -q '^StandardOutput=journal$' "$dropin"
    grep -q '^StandardError=journal$' "$dropin"
}

@test "mark_container: a tree that already redirects is left redirecting" {
    rootfs=$(fake_rootfs true)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT")" -eq 1 ]
}

@test "mark_container: a rootfs with no inithooks defaults fails loudly" {
    rootfs="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$rootfs"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not in the rootfs"* ]]
}

@test "mark_container: defaults that declare no REDIRECT_OUTPUT fail loudly" {
    rootfs=$(fake_rootfs)
    grep -v REDIRECT_OUTPUT "$rootfs/$BT_INITHOOKS_DEFAULT" > "$rootfs/trimmed"
    mv "$rootfs/trimmed" "$rootfs/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no REDIRECT_OUTPUT"* ]]
}

@test "spec_targets: both paths the first boot reads, under the rootfs" {
    output=$(bt_spec_targets /r)
    [ "$output" = $'/r/etc/keel/instance.yaml\n/r/etc/inithooks.yaml' ]
}

@test "secret_targets: the three secret files the spec references" {
    output=$(bt_secret_targets /r)
    [ "$output" = $'/r/etc/keel/secrets/root_password\n/r/etc/keel/secrets/db_password\n/r/etc/keel/secrets/app_password' ]
}

@test "webmin_verdict: the login page or a challenge is an answer" {
    run bt_webmin_verdict 200
    [ "$status" -eq 0 ]
    [[ $output == *"webmin answered 200 on port 12321"* ]]
    run bt_webmin_verdict 401
    [ "$status" -eq 0 ]
    run bt_webmin_verdict 000
    [ "$status" -eq 1 ]
    [[ $output == *"not 200 or 401"* ]]
    run bt_webmin_verdict 502
    [ "$status" -eq 1 ]
    run bt_webmin_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "module_verdict: the database module must be installed on the machine" {
    run bt_module_verdict webmin-mysql "install ok installed"
    [ "$status" -eq 0 ]
    [[ $output == *"webmin-mysql is installed"* ]]
    run bt_module_verdict webmin-mysql "install ok unpacked"
    [ "$status" -eq 1 ]
    [[ $output == *"is 'install ok unpacked'"* ]]
    run bt_module_verdict webmin-mysql
    [ "$status" -eq 1 ]
    [[ $output == *"is ''"* ]]
}

@test "db_verdict: the probe answer passes, anything else is a refusal" {
    run bt_db_verdict 1
    [ "$status" -eq 0 ]
    [[ $output == *"admin authenticated on [::1]:3306 with the declared password"* ]]
    run bt_db_verdict $'\n1\n'
    [ "$status" -eq 0 ]
    run bt_db_verdict "ERROR 1045 (28000): Access denied"
    [ "$status" -eq 1 ]
    [[ $output == *"did not reach the database"* ]]
    run bt_db_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "db_client_argv: the client call, with no password on the line" {
    output=$(bt_db_client_argv admin ::1 3306)
    [ "$output" = $'mysql\n--user=admin\n--host=::1\n--port=3306\n--protocol=TCP\n--batch\n--skip-column-names\n--execute=SELECT 1' ]
    [[ $output != *"MYSQL_PWD"* ]]
}

@test "db_client_argv: an empty user, host or a port that is not a number fails" {
    run ! bt_db_client_argv "" ::1 3306
    run ! bt_db_client_argv admin "" 3306
    run ! bt_db_client_argv admin ::1 ""
    run ! bt_db_client_argv admin ::1 threethousand
}

@test "spec_in_rootfs: secret references are pointed inside the rootfs" {
    printf 'secrets:\n  root_password:\n    file: /etc/keel/secrets/root_password\ntls:\n  acme:\n    enabled: false\n' > "$STUBS/spec"
    output=$(bt_spec_in_rootfs "$STUBS/spec" /r/rootfs)
    [[ $output == *"file: /r/rootfs/etc/keel/secrets/root_password"* ]]
    [[ $output == *"enabled: false"* ]]
    [[ $output != *"file: /etc/keel"* ]]
}

@test "random_password: 24 alphanumeric characters from the random source" {
    output=$(bt_random_password)
    [[ $output =~ ^[A-Za-z0-9]{24}$ ]]
    printf 'ab!!cd%%%%efghijklmnopqrstuvwxyz0123456789' > "$STUBS/random"
    output=$(BT_RANDOM_SOURCE=$STUBS/random bt_random_password)
    [ "$output" = abcdefghijklmnopqrstuvwx ]
}

@test "random_password: a source too poor to fill the password fails loudly" {
    printf '!!!!short!!!!' > "$STUBS/poor"
    BT_RANDOM_SOURCE="$STUBS/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ $output == *"gave only 5 usable characters"* ]]
}

@test "diff_verdict: 0 and 13 pass, everything else fails with a message" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [ "$output" = "keel diff: no drift" ]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ $output == *"could not be observed offline"* ]]
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ $output == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ $output == *"unreadable or invalid (exit 2)"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 127
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 127"* ]]
}

# --- the node options -------------------------------------------------

@test "parse_args: roles, the node library and the report are parsed" {
    bt_parse_args mariadb --roles "primary replica" \
        --nodes-lib /n/lib.sh --nodes-report /n/report
    [ "$BT_ROLES" = "primary replica" ]
    [ "$BT_NODES_LIB" = /n/lib.sh ]
    [ "$BT_NODES_REPORT" = /n/report ]
}

@test "parse_args: no roles means one node and nothing else set" {
    bt_parse_args mariadb
    [ -z "$BT_ROLES" ]
    [ -z "$BT_NODES_LIB" ]
    [ -z "$BT_NODES_REPORT" ]
}

@test "parse_args: roles without the node library is refused" {
    run bt_parse_args mariadb --roles "primary replica"
    [ "$status" -eq 1 ]
    [[ $output == *"--roles needs --nodes-lib"* ]]
}

@test "parse_args: a report with nothing to report is refused" {
    run bt_parse_args mariadb --nodes-report /n/report
    [ "$status" -eq 1 ]
    [[ $output == *"nothing to report without --roles"* ]]
}

@test "parse_args: each node option needs a value" {
    run ! bt_parse_args mariadb --roles
    run ! bt_parse_args mariadb --nodes-lib
    run ! bt_parse_args mariadb --nodes-report
    run ! bt_parse_args mariadb --keel-deb
}

@test "parse_args: a locally built keel is off unless it is asked for" {
    bt_parse_args mariadb
    [ -z "$BT_KEEL_DEB" ]
    bt_parse_args mariadb --keel-deb /root/src/keel_0.3.5_all.deb
    [ "$BT_KEEL_DEB" = /root/src/keel_0.3.5_all.deb ]
}

@test "keel_deb_argv: installs by name inside the node, never by path" {
    mapfile -t argv < <(bt_keel_deb_argv keel_0.3.5_all.deb)
    [ "${argv[0]}" = dpkg ]
    [ "${argv[1]}" = --install ]
    [ "${argv[2]}" = /root/keel_0.3.5_all.deb ]
}

@test "keel_deb_argv: refuses anything that is not a package file name" {
    run bt_keel_deb_argv ""
    [ "$status" -eq 1 ]
    [[ $output == *"is not a package file name"* ]]
    run ! bt_keel_deb_argv /root/src/keel.deb
    run ! bt_keel_deb_argv 'keel.deb; rm -rf /'
}

# --- the replication phase, driven by each node's description --------

@test "repl_prefix: the /64 of a global address, as a description writes it" {
    output=$(bt_repl_prefix fc42:5009:ba4b:5ab0:3a3c:c7b3:c779:316f)
    [ "$output" = 'fc42:5009:ba4b:5ab0::/64' ]
    output=$(bt_repl_prefix fc42:5009:ba4b:5ab0::2)
    [ "$output" = 'fc42:5009:ba4b:5ab0::/64' ]
}

@test "repl_prefix: refuses anything that is not a global IPv6" {
    run bt_repl_prefix ::1
    [ "$status" -eq 1 ]
    [[ $output == *"is not a global IPv6 address to authorise"* ]]
    run ! bt_repl_prefix 10.0.0.1
    run ! bt_repl_prefix fe80::1
}

@test "repl_prefix: refuses an address whose /64 is compressed away" {
    run bt_repl_prefix "fc42::2"
    [ "$status" -eq 1 ]
    [[ $output == *"no written out /64 prefix"* ]]
}

@test "repl_host_pattern: the /64 in MariaDB's own spelling, for one account" {
    output=$(bt_repl_host_pattern fc42:5009:ba4b:5ab0:3a3c:c7b3:c779:316f)
    [ "$output" = 'fc42:5009:ba4b:5ab0:%' ]
    run ! bt_repl_host_pattern ::1
}

@test "is_sql_literal: a generated password, and nothing needing an escape" {
    bt_is_sql_literal abcXYZ019
    bt_is_sql_literal 'fc42:5009:ba4b:5ab0:%'
    run ! bt_is_sql_literal ""
    run ! bt_is_sql_literal "it's"
    run ! bt_is_sql_literal 'back\slash'
    run ! bt_is_sql_literal 'two words'
}

@test "repl_section: a primary authorises the peer's prefix, not its address" {
    output=$(bt_repl_section primary fc42:5009:ba4b:5ab0::1 fc42:5009:ba4b:5ab0::2)
    [[ $output == *"role: primary"* ]]
    [[ $output == *'listen: ["::1", "127.0.0.1", "fc42:5009:ba4b:5ab0::1"]'* ]]
    [[ $output == *'allowed_from: ["fc42:5009:ba4b:5ab0::/64"]'* ]]
    [[ $output == *"file: /etc/keel/secrets/app_password"* ]]
    [[ $output != *"primary:"*"host:"* ]]
}

@test "repl_section: a replica names the endpoint it replicates from" {
    output=$(bt_repl_section replica fc42:5009:ba4b:5ab0::2 fc42:5009:ba4b:5ab0::1)
    [[ $output == *"role: replica"* ]]
    [[ $output == *'listen: ["::1", "127.0.0.1", "fc42:5009:ba4b:5ab0::2"]'* ]]
    [[ $output == *'host: "fc42:5009:ba4b:5ab0::1"'* ]]
    [[ $output == *"port: 3306"* ]]
    [[ $output != *"allowed_from"* ]]
}

@test "repl_section: refuses a role or an address it cannot describe" {
    run bt_repl_section arbiter fc42:5009:ba4b:5ab0::1 fc42:5009:ba4b:5ab0::2
    [ "$status" -eq 1 ]
    [[ $output == *"is neither primary nor replica"* ]]
    run bt_repl_section primary ::1 fc42:5009:ba4b:5ab0::2
    [ "$status" -eq 1 ]
    [[ $output == *"need global IPv6 addresses"* ]]
    run ! bt_repl_section replica fc42:5009:ba4b:5ab0::1 ::1
}

@test "apply_verdict: exit 0 converged, a refusal is quoted, anything else fails" {
    run bt_apply_verdict 0 "database.server: done"
    [ "$status" -eq 0 ]
    [[ $output == *"converged the declared role"* ]]
    run bt_apply_verdict 16 "x: refused: it holds operatordata"
    [ "$status" -eq 1 ]
    [[ $output == *"keel refused: it holds operatordata"* ]]
    run bt_apply_verdict 15 "must run as root"
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 15"* ]]
}

@test "refusal_verdict: the refusal is what is being proved" {
    run bt_refusal_verdict 16 "x: refused: this server holds operatordata"
    [ "$status" -eq 0 ]
    [[ $output == *"refused to replace the database this server holds"* ]]
}

@test "refusal_verdict: a run that went ahead is the failure" {
    run bt_refusal_verdict 0 "database.server.replication.primary: done"
    [ "$status" -eq 1 ]
    [[ $output == *"it must refuse"* ]]
}

@test "refusal_verdict: a refusal about something else is not this one, and is quoted" {
    run bt_refusal_verdict 16 "x: refused: no machine-id"
    [ "$status" -eq 1 ]
    [[ $output == *"said nothing about operatordata; it refused for another reason: no machine-id"* ]]
}

# run 37838543320: the replica applied before the primary had converged
# was refused for the primary's silence, which proves nothing about data
@test "refusal_verdict: the primary's silence is quoted as the reason, not mistaken for the data refusal" {
    run bt_refusal_verdict 16 "apply --system-only: 0 change(s), 1 failed
database.server.replication.primary: refused: the primary [fc42::1]:3306 did not answer as 'repl' (ERROR 2002). The replica cannot be seeded, so nothing was dropped"
    [ "$status" -eq 1 ]
    [[ $output == *"said nothing about operatordata; it refused for another reason: the primary [fc42::1]:3306 did not answer as 'repl'"* ]]
}

@test "refusal_verdict: exit 16 with no refusal line at all says so" {
    run bt_refusal_verdict 16 "apply --system-only: 0 change(s), 1 failed"
    [ "$status" -eq 1 ]
    [[ $output == *"said nothing about operatordata, and gave no refusal at all"* ]]
}

# the step the run is in, for the failure line the teardown adds

@test "step: records the step the run is in, name and text" {
    bt_step 8b "the primary converges first"
    [ "$BT_STEP" = "8b, the primary converges first" ]
    bt_step 8d "the refusal"
    [ "$BT_STEP" = "8d, the refusal" ]
}

@test "step: refuses a step with no name or no text" {
    run bt_step "" "text"
    [ "$status" -eq 1 ]
    [[ $output == *"a step needs a name and a text"* ]]
    run bt_step 8b ""
    [ "$status" -eq 1 ]
}

@test "step_failed: names the step on a failure, nothing on success or before the first step" {
    run bt_step_failed 1 "8d, the refusal: a replica that holds data is declined"
    [ "$status" -eq 0 ]
    [ "$output" = "boot-test: FAILED (exit 1) in step 8d, the refusal: a replica that holds data is declined" ]
    run bt_step_failed 0 "8d, the refusal"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_step_failed 1 ""
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dropin_verdict: the primary has a binary log and the replica has none" {
    run bt_dropin_verdict primary "server_id = 7
log_bin = mariadb-bin"
    [ "$status" -eq 0 ]
    [[ $output == *"binary log a replica can read"* ]]
    run bt_dropin_verdict replica "server_id = 8"
    [ "$status" -eq 0 ]
    [[ $output == *"needs no binary log of its own"* ]]
}

@test "dropin_verdict: a missing server id, log or an extra one all fail" {
    run bt_dropin_verdict primary "bind-address = ::1"
    [ "$status" -eq 1 ]
    [[ $output == *"names no server id"* ]]
    run bt_dropin_verdict primary "server_id = 7"
    [ "$status" -eq 1 ]
    [[ $output == *"has no binary log"* ]]
    run bt_dropin_verdict replica "server_id = 8
log_bin = mariadb-bin"
    [ "$status" -eq 1 ]
    [[ $output == *"given a binary log it does not need"* ]]
}

@test "repl_admin_sql: idempotent, and refuses a value needing an escape" {
    output=$(bt_repl_admin_sql admin 'fc42:5009:ba4b:5ab0:%' secret1)
    [[ $output == *"CREATE USER IF NOT EXISTS 'admin'@'fc42:5009:ba4b:5ab0:%'"* ]]
    [[ $output == *"ALTER USER 'admin'@'fc42:5009:ba4b:5ab0:%' IDENTIFIED BY 'secret1'"* ]]
    [[ $output == *"GRANT SELECT ON keeltest.* TO 'admin'@'fc42:5009:ba4b:5ab0:%'"* ]]
    # Never ALL: it carries Repl_slave_priv, which makes the machine a
    # primary in the server's own eyes and in what keel inspect reads.
    [[ $output != *"ALL PRIVILEGES"* ]]
    run bt_repl_admin_sql "adm'in" 'fc42:%' secret
    [ "$status" -eq 1 ]
    [[ $output == *"needs a plain user, host and password"* ]]
    run ! bt_repl_admin_sql admin 'fc42:%' "pass word"
}

@test "held_db_sql: the database the operator must be warned about" {
    output=$(bt_held_db_sql)
    [[ $output == *"CREATE DATABASE IF NOT EXISTS operatordata;"* ]]
    output=$(bt_drop_held_db_sql)
    [[ $output == *"DROP DATABASE IF EXISTS operatordata;"* ]]
}

@test "repl_write_sql: one row, with the marker of this run" {
    output=$(bt_repl_write_sql Zk9)
    [[ $output == *"CREATE DATABASE IF NOT EXISTS keeltest;"* ]]
    [[ $output == *"CREATE TABLE IF NOT EXISTS keeltest.proof"* ]]
    [[ $output == *"REPLACE INTO keeltest.proof (id, marker) VALUES (1, 'Zk9');"* ]]
}

@test "repl_write_sql: refuses a marker it did not generate" {
    run bt_repl_write_sql "'; DROP DATABASE keeltest; --"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a marker this test writes"* ]]
    run bt_repl_write_sql "$(printf 'a%.0s' {1..65})"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a marker this test writes"* ]]
    run bt_repl_write_sql ""
    [ "$status" -eq 1 ]
    [[ $output == *"is not a marker this test writes"* ]]
}

@test "repl_read_query: the one row, by key" {
    output=$(bt_repl_read_query)
    [ "$output" = "SELECT marker FROM keeltest.proof WHERE id = 1" ]
}

@test "repl_running_verdict: the server's own answer decides" {
    run bt_repl_running_verdict "$(printf 'Slave_running\tON\n')"
    [ "$status" -eq 0 ]
    [[ $output == *"reports Slave_running ON"* ]]
    run bt_repl_running_verdict "$(printf 'Slave_running\tOFF\n')"
    [ "$status" -eq 1 ]
    [[ $output == *"reports Slave_running 'OFF', not ON"* ]]
    run bt_repl_running_verdict ""
    [ "$status" -eq 1 ]
    [[ $output == *"reports Slave_running 'nothing'"* ]]
}

@test "repl_row_verdict: the row read on the replica is the row written" {
    run bt_repl_row_verdict Zk9 "$(printf 'Zk9\n')"
    [ "$status" -eq 0 ]
    [[ $output == *"returned the row written on the primary (Zk9)"* ]]
}

@test "repl_row_verdict: a different row, no row, or nothing expected, fails" {
    run bt_repl_row_verdict Zk9 "other"
    [ "$status" -eq 1 ]
    [[ $output == *"returned 'other', not the row written"* ]]
    run ! bt_repl_row_verdict Zk9 ""
    run ! bt_repl_row_verdict "" ""
}

# run 37842190136 on keel-lxc-1: the client said "Can't connect to server
# on '::1' (115)" and the run ended with nothing about why the server was
# not there; the node is asked for its unit and the journals instead
@test "db_diagnostics_argv: the unit's status and the journals of the server and the first boot, through one shell" {
    run bt_db_diagnostics_argv mariadb.service
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = sh ]
    [ "${lines[1]}" = -c ]
    [ "${lines[2]}" = "systemctl status --no-pager -l mariadb.service; journalctl --no-pager -n 60 -o short-precise -u mariadb.service -u inithooks.service" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "db_diagnostics_argv: refuses an empty unit or one that is not a unit name" {
    run bt_db_diagnostics_argv ""
    [ "$status" -eq 1 ]
    run bt_db_diagnostics_argv "mariadb.service; rm -rf /"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "db_argv: the client command for a query this test chooses" {
    output=$(bt_db_argv admin fc42::2 3306 "SELECT marker FROM t")
    [ "$output" = $'mysql\n--user=admin\n--host=fc42::2\n--port=3306\n--protocol=TCP\n--batch\n--skip-column-names\n--execute=SELECT marker FROM t' ]
}

@test "db_argv: refuses an empty field or a port that is not a number" {
    run ! bt_db_argv "" fc42::2 3306 "SELECT 1"
    run ! bt_db_argv admin "" 3306 "SELECT 1"
    run ! bt_db_argv admin fc42::2 3306 ""
    run ! bt_db_argv admin fc42::2 "" "SELECT 1"
    run ! bt_db_argv admin fc42::2 threethousand "SELECT 1"
}
