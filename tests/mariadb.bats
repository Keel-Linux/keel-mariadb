#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/lib/mariadb.sh, the logic behind
# the first boot hook 35mysqlpass (decision 0004). Every function is pure:
# nothing here needs a database, root or a network.

bats_require_minimum_version 1.5.0

setup() {
    load ../overlay/usr/lib/inithooks/lib/mariadb.sh
}

@test "first_value: the first value that is set and is not DEFAULT" {
    [ "$(mariadb_first_value "" DEFAULT keeper other)" = keeper ]
    [ "$(mariadb_first_value default keeper)" = keeper ]
    [ "$(mariadb_first_value Default keeper)" = keeper ]
    [ "$(mariadb_first_value first second)" = first ]
    run ! mariadb_first_value "" DEFAULT ""
    run ! mariadb_first_value
}

@test "admin_user: the layer's account, or the one APP_DB_USER names" {
    [ "$(mariadb_admin_user)" = admin ]
    [ "$(mariadb_admin_user "")" = admin ]
    [ "$(mariadb_admin_user DEFAULT)" = admin ]
    [ "$(mariadb_admin_user lampuser)" = lampuser ]
    MARIADB_ADMIN_USER=dba
    [ "$(mariadb_admin_user)" = dba ]
}

@test "admin_user: a name that would need quoting in a GRANT is refused" {
    run ! mariadb_admin_user "rm -rf /"
    run ! mariadb_admin_user "'admin'"
    run ! mariadb_admin_user "9lives"
    run ! mariadb_admin_user "a b"
    run ! mariadb_admin_user "ad;min"
}

@test "is_user_name: what this layer will put in a GRANT" {
    mariadb_is_user_name admin
    mariadb_is_user_name _admin
    mariadb_is_user_name lamp-user
    mariadb_is_user_name a1
    run ! mariadb_is_user_name ""
    run ! mariadb_is_user_name "1a"
    run ! mariadb_is_user_name "a%"
}

@test "admin_hosts: the socket host and both loopback addresses, IPv6 first" {
    output=$(mariadb_admin_hosts)
    [ "$output" = $'localhost\n::1\n127.0.0.1' ]
    MARIADB_ADMIN_HOSTS="localhost"
    [ "$(mariadb_admin_hosts)" = localhost ]
}

@test "missing_values: DB_PASS only when the description declared none" {
    [ -z "$(mariadb_missing_values s3cret)" ]
    [ "$(mariadb_missing_values "")" = DB_PASS ]
    [ "$(mariadb_missing_values)" = DB_PASS ]
}

@test "conf_args: the mysqlconf.py call for one account" {
    output=$(mariadb_conf_args admin ::1 s3cret)
    [ "$output" = $'--user=admin\n--host=::1\n--pass=s3cret' ]
}

@test "conf_args: no account, no host and no empty password" {
    run ! mariadb_conf_args "" ::1 s3cret
    run ! mariadb_conf_args "a b" ::1 s3cret
    run ! mariadb_conf_args admin "" s3cret
    run ! mariadb_conf_args admin ::1 ""
}

@test "verify_args: the client call that proves the password, without it" {
    output=$(mariadb_verify_args admin ::1 3306)
    [ "$output" = $'--user=admin\n--host=::1\n--port=3306\n--protocol=TCP\n--batch\n--skip-column-names\n--execute=SELECT 1' ]
    [[ $output != *s3cret* ]]
}

@test "verify_args: the port must be a positive number" {
    run ! mariadb_verify_args admin ::1 ""
    run ! mariadb_verify_args admin ::1 0
    run ! mariadb_verify_args admin ::1 33o6
    run ! mariadb_verify_args admin "" 3306
    run ! mariadb_verify_args "" ::1 3306
}

@test "wait_ready: returns as soon as the command succeeds" {
    MARIADB_SLEEP=:
    attempts=0
    probe() { attempts=$((attempts + 1)); [ "$attempts" -ge 3 ]; }
    mariadb_wait_ready probe 10
    [ "$attempts" -eq 3 ]
}

@test "wait_ready: gives up after the last try" {
    MARIADB_SLEEP=:
    attempts=0
    never() { attempts=$((attempts + 1)); return 1; }
    run ! mariadb_wait_ready never 4
}

@test "masked: a length, never the password" {
    [ "$(mariadb_masked s3cret)" = "(6 characters)" ]
    [ "$(mariadb_masked "")" = "(none)" ]
    [ "$(mariadb_masked)" = "(none)" ]
    [[ "$(mariadb_masked s3cret)" != *s3cret* ]]
}
