#!/usr/bin/env bats
# bin/keel-socket-wildcard against scratch trees: the socket units of a
# built tree, and whether one of them can listen on a wildcard address for
# the port (keel-mariadb#29). The unit files are the shape Debian's
# mariadb-server 1:11.8.6-0+deb13u1 ships on trixie.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECK="$REPO/bin/keel-socket-wildcard"
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/usr/lib/systemd/system" "$ROOT/etc/systemd/system"
}

# unit NAME TEXT: a unit file under usr/lib/systemd/system
unit() {
    printf '%s\n' "$2" > "$ROOT/usr/lib/systemd/system/$1"
}

mariadb_socket() {
    unit mariadb.socket '[Unit]
Description=MariaDB 11.8.6 database server (socket activation)

[Socket]
SocketUser=mysql
SocketMode=777
ListenStream=@mariadb
ListenStream=/run/mysqld/mysqld.sock
ListenStream=3306

[Install]
WantedBy=sockets.target'
}

mariadb_extra_socket() {
    unit mariadb-extra.socket '[Socket]
ListenStream=@mariadb-extra
ListenStream=/run/mysqld/mysqld.sock-extra'
}

mask() {
    ln -s /dev/null "$ROOT/etc/systemd/system/$1"
}

@test "Debian's mariadb.socket, as shipped, listens on a wildcard for 3306" {
    mariadb_socket
    mariadb_extra_socket
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
    [[ $output == *"mariadb.socket: ListenStream=3306"* ]]
    [[ $output != *"mariadb-extra.socket"* ]]
}

@test "masked, it is no listener: the tree passes" {
    mariadb_socket
    mariadb_extra_socket
    mask mariadb.socket
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
    [[ $output == *"no socket unit"*"3306"* ]]
}

@test "disabled is not enough: a first boot's presets enable it again" {
    mariadb_socket
    # no sockets.target.wants link, and still a finding
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
}

@test "every wildcard spelling of the port is found" {
    for listen in 3306 '0.0.0.0:3306' '[::]:3306' ' 3306' '3306 '; do
        unit db.socket "[Socket]
ListenStream=$listen"
        run "$CHECK" "$ROOT" 3306
        [ "$status" -eq 1 ] || { echo "not found: '$listen'"; false; }
    done
}

@test "ListenDatagram and ListenSequentialPacket count, with spaces round the =" {
    unit db.socket '[Socket]
ListenDatagram = 3306'
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
    unit db.socket '[Socket]
ListenSequentialPacket=[::]:3306'
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
}

@test "an address, loopback, a path, an abstract name or another port is not a wildcard" {
    unit db.socket '[Socket]
ListenStream=[::1]:3306
ListenStream=127.0.0.1:3306
ListenStream=[fd11:a58a:88ef::ffff:1]:3306
ListenStream=/run/mysqld/mysqld.sock
ListenStream=@mariadb
ListenStream=33060
ListenStream=[::]:13306
# ListenStream=3306
; ListenStream=3306'
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
}

@test "a drop-in that adds the port is found" {
    unit db.socket '[Socket]
ListenStream=/run/db.sock'
    mkdir -p "$ROOT/etc/systemd/system/db.socket.d"
    printf '[Socket]\nListenStream=3306\n' > "$ROOT/etc/systemd/system/db.socket.d/50-tcp.conf"
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
    [[ $output == *"db.socket: ListenStream=3306"* ]]
}

@test "an empty ListenStream= in a drop-in clears the list before it" {
    mariadb_socket
    mkdir -p "$ROOT/usr/lib/systemd/system/mariadb.socket.d"
    printf '[Socket]\nListenStream=\nListenStream=/run/mysqld/mysqld.sock\n' \
        > "$ROOT/usr/lib/systemd/system/mariadb.socket.d/10-unix.conf"
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
}

@test "a unit under etc replaces the one of the same name under usr/lib" {
    mariadb_socket
    printf '[Socket]\nListenStream=[::1]:3306\n' > "$ROOT/etc/systemd/system/mariadb.socket"
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
}

@test "units under lib/systemd/system are read too" {
    mkdir -p "$ROOT/lib/systemd/system"
    printf '[Socket]\nListenStream=3306\n' > "$ROOT/lib/systemd/system/old.socket"
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 1 ]
    [[ $output == *"old.socket"* ]]
}

@test "the port defaults to 3306" {
    mariadb_socket
    run "$CHECK" "$ROOT"
    [ "$status" -eq 1 ]
}

@test "another port is checked when it is given" {
    unit redis.socket '[Socket]
ListenStream=6379'
    run "$CHECK" "$ROOT" 6379
    [ "$status" -eq 1 ]
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
}

@test "a tree with no socket unit passes" {
    run "$CHECK" "$ROOT" 3306
    [ "$status" -eq 0 ]
}

@test "no root, a root that is not a directory, or a bad port is a usage error" {
    run "$CHECK"
    [ "$status" -eq 2 ]
    run "$CHECK" "$BATS_TEST_TMPDIR/missing" 3306
    [ "$status" -eq 2 ]
    run "$CHECK" "$ROOT" port
    [ "$status" -eq 2 ]
    [[ $output == *"usage"* ]]
}
