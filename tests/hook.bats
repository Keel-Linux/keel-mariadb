#!/usr/bin/env bats
# The first boot hook firstboot.d/35mysqlpass (decision 0004): every path it
# takes runs for real against scratch directories, and every command that
# would touch the system (systemctl, mysqladmin, mysql, bin/mysqlconf.py,
# bin/dbpass.py) is a stub that records its arguments. Nothing here needs
# root, a database or a network.
#
# What these tests are really about is the defect these two layers exposed:
# an instance description declares secrets.db_password, the renderer writes
# DB_PASS, and nothing on the MariaDB side read it, because the only hook
# that calls mysqlconf.py ships with Adminer. So the first test is that
# DB_PASS, and nothing else, is what sets the password.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/35mysqlpass"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin"
    # the library is the real file, not a copy: kcov measures the one the
    # appliance ships, and a copy per test would be measured as its own
    # uncovered file
    ln -s "$(cd "$ROOT/overlay/usr/lib/inithooks/lib" && pwd)" "$scratch/inithooks/lib"
    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export MARIADB_SLEEP=:

    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub mysqladmin 'echo "mysqladmin $*" >> "$CALLS"'
    # the client the hook proves the password with: it refuses anything but
    # the password the stubbed mysqlconf.py recorded, the way a server would
    stub mysql 'echo "mysql $* MYSQL_PWD=$MYSQL_PWD" >> "$CALLS"
if [ -f "$CALLS.pass" ] && [ "$MYSQL_PWD" = "$(cat "$CALLS.pass")" ]; then echo 1; else echo "ERROR 1045 (28000): Access denied"; exit 1; fi'
    tool mysqlconf.py 'echo "mysqlconf.py $*" >> "$CALLS"
for arg in "$@"; do case "$arg" in --pass=*) printf "%s" "${arg#--pass=}" > "$CALLS.pass" ;; esac; done'
    tool dbpass.py 'echo "dbpass.py $*" >> "$CALLS"; echo "DB_PASS=typed-at-the-console"'
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

tool() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/inithooks/bin/$1"
    chmod +x "$scratch/inithooks/bin/$1"
}

# write_conf [EXTRA_LINE...]: the conf a declared description renders to
write_conf() {
    printf 'export DB_PASS=%s\n' "$DECLARED_PASS" > "$INITHOOKS_CONF"
    printf '%s\n' "$@" >> "$INITHOOKS_CONF"
}

DECLARED_PASS=s3cret-from-the-description

@test "the declared password is what reaches the database" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "mysqlconf.py --user=admin --host=localhost --pass=s3cret-from-the-description" "$CALLS"
    grep -q -- "mysqlconf.py --user=admin --host=::1 --pass=s3cret-from-the-description" "$CALLS"
    grep -q -- "mysqlconf.py --user=admin --host=127.0.0.1 --pass=s3cret-from-the-description" "$CALLS"
    [[ "$output" == *"set from DB_PASS (${#DECLARED_PASS} characters)"* ]]
    [[ "$output" != *"$DECLARED_PASS"* ]]
}

@test "the hook proves the password by connecting, and says where" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "mysql --user=admin --host=::1 --port=3306 --protocol=TCP" "$CALLS"
    grep -q -- "MYSQL_PWD=s3cret-from-the-description" "$CALLS"
    [[ "$output" == *"verified on [::1]:3306"* ]]
}

@test "a password the database does not accept fails the hook" {
    write_conf
    tool mysqlconf.py 'echo "mysqlconf.py $*" >> "$CALLS"'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot authenticate on [::1]:3306 with the declared password"* ]]
}

@test "MYSQL_PASS in the conf is not a password: it is a build time variable" {
    printf 'export MYSQL_PASS=from-the-build\n' > "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS in $INITHOOKS_CONF"* ]]
    [ ! -f "$CALLS" ] || ! grep -q "from-the-build" "$CALLS"
}

@test "a headless first boot with no declared password fails and says so" {
    printf 'export HOSTNAME=db\n' > "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
    [[ "$output" == *"declare secrets.db_password in the instance description"* ]]
}

@test "no conf at all is the same headless failure" {
    rm -f "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
}

@test "the dialog value is used when the hook is given a terminal" {
    printf 'export HOSTNAME=db\n' > "$INITHOOKS_CONF"
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 0 ]
    grep -q -- "dbpass.py DB_PASS" "$CALLS"
    grep -q -- "--pass=typed-at-the-console" "$CALLS"
}

@test "an empty answer from the dialog is not a password" {
    printf 'export HOSTNAME=db\n' > "$INITHOOKS_CONF"
    tool dbpass.py 'echo "DB_PASS="'
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no password given"* ]]
}

@test "APP_DB_USER names the account the password belongs to" {
    write_conf "export APP_DB_USER=lampuser"
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "mysqlconf.py --user=lampuser --host=localhost" "$CALLS"
    grep -q -- "mysql --user=lampuser --host=::1" "$CALLS"
}

@test "an APP_DB_USER this layer will not create fails before anything runs" {
    write_conf "export APP_DB_USER='rm -rf /'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an account name this layer will create"* ]]
    [ ! -f "$CALLS" ]
}

@test "the service is started and waited for before the password is set" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "systemctl start mariadb.service" ]
    [ "$(sed -n 2p "$CALLS")" = "mysqladmin ping" ]
}

@test "a server that never answers fails the hook before the password" {
    write_conf
    stub mysqladmin 'exit 1'
    export MARIADB_WAIT_TRIES=2
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mariadb did not answer after 2 tries"* ]]
    run ! grep -q mysqlconf.py "$CALLS"
}
