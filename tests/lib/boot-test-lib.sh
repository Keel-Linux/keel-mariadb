#!/bin/bash
# Pure helpers of tests/boot-test.sh (decision 0004: logic apart from
# effect). Same shape as the one in keel-core and keel-nodebb, with the
# checks this layer adds: a client connection to the database with the
# password the instance description declared, the Webmin module for that
# database, and Webmin answering over IPv6. Nothing here starts a
# container, writes outside a path it is given or opens a socket. The two
# functions that run a command, bt_now and bt_container_ipv6, take it from
# the environment or from PATH so a test can replace it. Sourced by
# boot-test.sh and by tests/boot-test.bats.
# shellcheck disable=SC2034  # the BT_* variables are read by the caller

BT_DEFAULT_TIMEOUT=900
BT_DEFAULT_INTERVAL=5
BT_DEFAULT_BRIDGE=br0
BT_DEFAULT_LAYERS_DIR=/mnt/builds/layers
BT_DEFAULT_CACHE_DIR=/var/cache/keel/layers
BT_DEFAULT_LXC_PATH=/var/lib/lxc
BT_SSH_PORT=22
BT_PASSWORD_LENGTH=24
BT_RANDOM_BYTES=1024
# The secrets tests/instance.yaml references, one file each under
# etc/keel/secrets in the rootfs: the root account, the database account,
# which is the one this layer exists for, and app_password, which the
# replication phase uses for the replication account. One set of values is
# generated per run and written into every node, because a replica is a
# copy of its primary and an operator deploys one description to both.
BT_SECRETS="root_password db_password app_password"
# The panel core carries and this layer adds a module to.
BT_WEBMIN_PORT=12321
BT_WEBMIN_MODULE=webmin-mysql
# The database connection the test proves. The client runs inside the
# container, because the database listens on loopback only: an appliance
# above this layer talks to it from the same machine, and opening it to
# the network is that appliance's decision, not this layer's.
BT_DB_USER="admin"
BT_DB_HOST=::1
BT_DB_PORT=3306
BT_DB_PROBE_QUERY="SELECT 1"
BT_DB_PROBE_ANSWER=1
# Where the first boot reads the instance description. inithooks reads
# etc/inithooks.yaml (hook 00declarative), keel reads etc/keel/instance.yaml;
# the final name is a maintainer decision (brief section 11), so the test
# installs the same file at both until then.
BT_SPEC_PATHS="etc/keel/instance.yaml etc/inithooks.yaml"
# What marks the tree as a container build, relative to the rootfs: the
# marker file bt-container writes, the inithooks defaults whose
# REDIRECT_OUTPUT it sets, and the drop-in that keeps the first boot off
# tty1. See bt_mark_container.
BT_CONTAINER_MARKER="var/lib/turnkey-info/inithooks.service/lxc"
BT_INITHOOKS_DEFAULT="etc/default/inithooks"
BT_INITHOOKS_DROPIN="etc/systemd/system/inithooks.service.d/container.conf"

# The replication phase, which runs only when --roles asks for more than one
# node. The test configures nothing here any more: it writes each node's
# role into that node's own instance description and runs
# `keel spec apply --system-only`, which is what an operator does from the
# console (handbook decision 0013, keel docs/apply.md). What is left below
# is what a test is for: the description to write, and the questions the
# servers are asked afterwards.
BT_ROLE_PRIMARY=primary
BT_ROLE_REPLICA=replica
BT_REPL_USER=repl
BT_REPL_DB=keeltest
BT_REPL_TABLE=proof
# The drop-in keel writes from database.server. The test never writes it;
# it reads it back, because a file keel says it wrote is a file that has
# to be there.
BT_REPL_CNF="etc/mysql/mariadb.conf.d/99-keel-database.cnf"
# The secret the description names for the replication account. One value
# per run, written into every node, because both ends of a pair hold the
# same credential and an operator deploys one description to both.
BT_REPL_SECRET="/etc/keel/secrets/app_password"
BT_REPL_RUNNING_QUERY="SHOW GLOBAL STATUS LIKE 'Slave_running'"
BT_REPL_RUNNING_ANSWER=ON
# What proves the refusal on a real machine: a database that is nobody's
# business but the operator's, created on the node that is about to be
# told to become a replica.
BT_REPL_HELD_DB=operatordata
BT_REPL_REFUSED="refused: "
BT_APPLY_FAILED=16
# What a node is asked when its database never answered the client at all:
# the server's unit and the first boot's, their last lines in the journal.
BT_DB_SERVICE=mariadb.service
BT_DIAGNOSTIC_LINES=60
# The marker column is VARCHAR(64), so a longer value would be truncated on
# the way in and the comparison on the replica would fail for a reason that
# has nothing to do with replication.
BT_REPL_MARKER_MAX=64

bt_usage() {
    cat <<USAGE
usage: tests/boot-test.sh APPLIANCE [options]

Assembles the layer chain of APPLIANCE (mariadb) into an LXC rootfs, boots
it headless from tests/instance.yaml, waits for the first boot to finish,
connects to the database with the password the description declared,
checks the Webmin module and Webmin over IPv6, and checks that keel diff
reports no drift. Root only.

With --roles it does the same for one container per role on the same
bridge, then configures the primary and the replica by hand, writes a row
on the primary and reads it on the replica over IPv6.

options:
  --timeout SECONDS     give up after this long per wait (default $BT_DEFAULT_TIMEOUT)
  --interval SECONDS    poll interval (default $BT_DEFAULT_INTERVAL)
  --bridge NAME         bridge the container joins (default $BT_DEFAULT_BRIDGE)
  --layers-dir DIR|URL  where the layers are published: a directory, or an
                        http(s) URL such as https://mirror.keellinux.org/layers
                        (default $BT_DEFAULT_LAYERS_DIR)
  --cache-dir DIR       keel layer cache (default $BT_DEFAULT_CACHE_DIR)
  --lxc-path DIR        lxcpath for the test containers (default $BT_DEFAULT_LXC_PATH)
  --name NAME           container name with one node, and the base the node
                        names are derived from with several: NAME-1, NAME-2
                        (default keel-APPLIANCE-boot-test)
  --spec FILE           instance spec (default tests/instance.yaml)
  --roles "A B"         one role name per node, "$BT_ROLE_PRIMARY $BT_ROLE_REPLICA" for the
                        replication phase. Empty, the default, is one node
  --nodes-lib FILE      lib/boot-test-nodes.sh of keel-linux/.github, which
                        the reusable workflow clones and passes. Required
                        with --roles
  --nodes-report FILE   write the topology, one "INDEX NAME ROLE ADDRESS"
                        per line, for the workflow's job summary
  --keel-deb FILE       install this locally built keel package into every
                        node once it has booted, for proving a keel that no
                        published layer carries yet
  --keep                leave the containers running for inspection
  -h, --help            this text
USAGE
}

bt_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

bt_is_appliance_name() {
    # The name bt-layer and the workflow use: no keel- prefix, lower case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ $1 != keel-* ]]
}

bt_container_name() {
    printf 'keel-%s-boot-test\n' "$1"
}

bt_is_container_name() {
    # What LXC accepts and what the CI cleanup command allows: lower case
    # letters, digits, dot and dash, starting with a letter or a digit.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Sets BT_APPLIANCE, BT_TIMEOUT, BT_INTERVAL, BT_BRIDGE, BT_LAYERS_DIR,
# BT_CACHE_DIR, BT_LXC_PATH, BT_SPEC, BT_KEEL_DEB, BT_KEEP, BT_NAME and
# BT_ROOTFS.
# Returns 0 when parsed, 2 after printing the usage, 1 on a bad argument
# (message on stderr).
bt_parse_args() {
    BT_APPLIANCE=""
    BT_TIMEOUT=$BT_DEFAULT_TIMEOUT
    BT_INTERVAL=$BT_DEFAULT_INTERVAL
    BT_BRIDGE=$BT_DEFAULT_BRIDGE
    BT_LAYERS_DIR=$BT_DEFAULT_LAYERS_DIR
    BT_CACHE_DIR=$BT_DEFAULT_CACHE_DIR
    BT_LXC_PATH=$BT_DEFAULT_LXC_PATH
    BT_NAME=""
    BT_SPEC=""
    BT_ROLES=""
    BT_NODES_LIB=""
    BT_NODES_REPORT=""
    BT_KEEL_DEB=""
    BT_KEEP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout|--interval)
                bt_is_positive_int "${2-}" || {
                    echo "boot-test: $1 needs a positive number of seconds" >&2
                    return 1
                }
                [ "$1" = --timeout ] && BT_TIMEOUT=$2 || BT_INTERVAL=$2
                shift
                ;;
            --bridge|--layers-dir|--cache-dir|--lxc-path|--name|--spec|--roles|--nodes-lib|--nodes-report|--keel-deb)
                [ -n "${2-}" ] || {
                    echo "boot-test: $1 needs a value" >&2
                    return 1
                }
                case "$1" in
                    --bridge) BT_BRIDGE=$2 ;;
                    --layers-dir) BT_LAYERS_DIR=$2 ;;
                    --cache-dir) BT_CACHE_DIR=$2 ;;
                    --lxc-path) BT_LXC_PATH=$2 ;;
                    --name) BT_NAME=$2 ;;
                    --spec) BT_SPEC=$2 ;;
                    --roles) BT_ROLES=$2 ;;
                    --nodes-lib) BT_NODES_LIB=$2 ;;
                    --nodes-report) BT_NODES_REPORT=$2 ;;
                    --keel-deb) BT_KEEL_DEB=$2 ;;
                esac
                shift
                ;;
            --keep) BT_KEEP=1 ;;
            -h|--help)
                bt_usage
                return 2
                ;;
            -*)
                echo "boot-test: unknown option $1" >&2
                return 1
                ;;
            *)
                if [ -n "$BT_APPLIANCE" ]; then
                    echo "boot-test: one appliance at a time ($BT_APPLIANCE, $1)" >&2
                    return 1
                fi
                BT_APPLIANCE=$1
                ;;
        esac
        shift
    done
    if [ -z "$BT_APPLIANCE" ]; then
        echo "boot-test: APPLIANCE is required (core, lamp, ...)" >&2
        return 1
    fi
    if ! bt_is_appliance_name "$BT_APPLIANCE"; then
        echo "boot-test: '$BT_APPLIANCE' is not an appliance name (lower case, no keel- prefix)" >&2
        return 1
    fi
    BT_NAME=${BT_NAME:-$(bt_container_name "$BT_APPLIANCE")}
    if ! bt_is_container_name "$BT_NAME"; then
        echo "boot-test: '$BT_NAME' is not a container name (lower case, digits, dot, dash)" >&2
        return 1
    fi
    if [ -n "$BT_ROLES" ] && [ -z "$BT_NODES_LIB" ]; then
        echo "boot-test: --roles needs --nodes-lib (lib/boot-test-nodes.sh of keel-linux/.github)" >&2
        return 1
    fi
    if [ -z "$BT_ROLES" ] && [ -n "$BT_NODES_REPORT" ]; then
        echo "boot-test: --nodes-report has nothing to report without --roles" >&2
        return 1
    fi
    BT_ROOTFS=$BT_LXC_PATH/$BT_NAME/rootfs
    return 0
}

bt_is_global_ipv6() {
    # Global unicast, which includes ULA (fc00::/7); not link local
    # (fe80::/10), loopback or multicast. IPv4 has no colon.
    local addr=${1,,}
    [[ $addr == *:* ]] || return 1
    [[ $addr == fe[89ab]?:* ]] && return 1
    [[ $addr == ::1 ]] && return 1
    [[ $addr == ff* ]] && return 1
    return 0
}

bt_global_ipv6() {
    # stdin: the output of lxc-info -i ("IP:  ADDRESS" per line). Prints
    # the first global IPv6 address; returns 1 when there is none yet.
    local label addr _
    while read -r label addr _; do
        [ "$label" = "IP:" ] || continue
        if bt_is_global_ipv6 "$addr"; then
            printf '%s\n' "$addr"
            return 0
        fi
    done
    return 1
}

bt_container_ipv6() {
    # bt_container_ipv6 NAME LXCPATH: the container's first global IPv6.
    lxc-info -P "$2" -n "$1" -i 2>/dev/null | bt_global_ipv6
}

bt_now() {
    ${BT_CLOCK:-date +%s}
}

bt_deadline_passed() {
    # bt_deadline_passed START TIMEOUT NOW
    [ $(( $3 - $1 )) -ge "$2" ]
}

bt_wait_for() {
    # bt_wait_for TIMEOUT INTERVAL DESCRIPTION COMMAND [ARGS...]
    # Runs COMMAND until it succeeds; returns 1 once TIMEOUT seconds passed.
    local timeout=$1 interval=$2 what=$3 start now
    shift 3
    start=$(bt_now)
    until "$@"; do
        now=$(bt_now)
        if bt_deadline_passed "$start" "$timeout" "$now"; then
            echo "boot-test: timeout after ${timeout}s waiting for $what" >&2
            return 1
        fi
        ${BT_SLEEP:-sleep} "$interval"
    done
}

bt_is_ssh_banner() {
    [[ ${1-} == SSH-2.0-* ]]
}

bt_firstboot_done_in() {
    # bt_firstboot_done_in FILE: FILE is the rootfs copy of
    # /etc/default/inithooks; 98finalize sets RUN_FIRSTBOOT=false at the end.
    [ -r "$1" ] && grep -q '^RUN_FIRSTBOOT=false' "$1"
}

bt_lxc_config() {
    # bt_lxc_config NAME ROOTFS BRIDGE: an LXC config for a plain rootfs
    # directory on a bridge; the address comes from the bridge (SLAAC or
    # DHCPv6), the spec declares managed_by: host.
    #
    # The apparmor pair is not decoration, and this layer is the clearest
    # case of why. Under the stock container profile systemd cannot give a
    # unit a mount namespace, so every unit with ProtectSystem or
    # ProtectHome fails with status=226/NAMESPACE before its own first
    # line runs. mariadb.service has both, so the database never started,
    # firstboot.d/35mysqlpass could not set the declared password, and
    # nothing listened on 3306. Measured in the same container:
    # systemd-journald, systemd-logind, systemd-sysusers, systemd-sysctl
    # and tmp.mount failed the same way, which is why 15regen-sslcert and
    # 95secupdates failed beside it. A generated profile with nesting
    # allowed is what a container running systemd needs, and it is what
    # the appliance containers on the build host have carried all along.
    cat <<CONFIG
lxc.uts.name = $1
lxc.rootfs.path = dir:$2
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = amd64
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.net.0.type = veth
lxc.net.0.link = $3
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.start.auto = 0
CONFIG
}

bt_mark_container() {
    # bt_mark_container ROOTFS: make the tree look like the container build
    # buildtasks produces, which is two things, both from its
    # patches/container/conf:
    #
    #   the marker under /var/lib/turnkey-info, which inithooks' unit
    #   conditions read and which `keel inspect` reads to call the machine a
    #   container (network.managed_by: host), and
    #
    #   REDIRECT_OUTPUT=true in /etc/default/inithooks, which sends first
    #   boot output to the log with a tail on the active console instead of
    #   writing it straight to tty1,
    #
    # and a drop-in that keeps the first boot off tty1.
    #
    # The last two are not cosmetic. The layer ships the plain appliance
    # inithooks.service, which runs the hooks with StandardOutput=tty on
    # /dev/tty1; the unit a container image gets instead logs to syslog and
    # the console. Nothing reads tty1 in a container nobody has attached to,
    # so a hook that prints more than the terminal buffer holds blocks in
    # the write and never returns. keel-nodebb found it the hard way, with
    # `./nodebb setup` asleep in n_tty_write and a first boot that never
    # finished; this is the same function, so the next hook that prints a
    # lot does not find it again.
    local rootfs=$1 defaults=$1/$BT_INITHOOKS_DEFAULT
    install -D -m 0644 /dev/null "$rootfs/$BT_CONTAINER_MARKER" || return 1
    if [ ! -f "$defaults" ]; then
        echo "boot-test: $defaults is not in the rootfs" >&2
        return 1
    fi
    sed -i '/REDIRECT_OUTPUT/ s/=.*/=true/' "$defaults" || return 1
    if ! grep -q '^REDIRECT_OUTPUT=true$' "$defaults"; then
        echo "boot-test: $defaults declares no REDIRECT_OUTPUT to set" >&2
        return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_INITHOOKS_DROPIN" <<DROPIN || return 1
[Service]
StandardOutput=journal
StandardError=journal
DROPIN
}

# What pct create of Proxmox VE writes into a new container
# (PVE::LXC::Setup::Base, setup_systemd_preset), read off CT 9003 on
# 2026-10-09. Kept as Proxmox VE writes it, comment line included.
BT_PVE_PRESET="etc/systemd/system-preset/00-pve.preset"
BT_PVE_PRESET_TEXT="# Added by PVE at create-time for first-boot configuration.
enable container-getty@.service
disable getty@.service
disable sys-kernel-config.mount
disable sys-kernel-debug.mount
disable systemd-networkd.service"

bt_pve_create() {
    # bt_pve_create ROOTFS: do to the tree what pct create of Proxmox VE
    # does to a new container (clear_machine_id, not a clone): remove
    # /etc/machine-id, and /var/lib/dbus/machine-id unless it is a link,
    # and write the preset. With no machine id the first start is the
    # first boot of systemd, which enables every unit that no preset
    # disables (machine-id(5), "First Boot Semantics"). That is how
    # mariadb.socket came to listen on [::]:3306 on the real nodes (#29),
    # and a tree that keeps its machine id never shows it.
    local rootfs=${1-} dbus
    if [ ! -d "$rootfs/etc" ]; then
        echo "boot-test: $rootfs is not a rootfs (no etc)" >&2
        return 1
    fi
    rm -f "$rootfs/etc/machine-id" || return 1
    dbus=$rootfs/var/lib/dbus/machine-id
    if [ -e "$dbus" ] && [ ! -L "$dbus" ]; then
        rm -f "$dbus" || return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_PVE_PRESET" <<< "$BT_PVE_PRESET_TEXT" || return 1
    echo "boot-test: $rootfs made as pct create makes it: no machine id, so its first start is the first boot of systemd"
}

# The local address is the fourth field of `ss -Hltn`; one line, so that
# it is a line that runs.
BT_WILDCARD_PROGRAM='NF >= 4 && $4 ~ ("^([*]|[[]::[]]|0[.]0[.]0[.]0)(%[^:]+)?:" port "$") { print $4 }'

bt_wildcard_listeners() {
    # bt_wildcard_listeners PORT: of the `ss -Hltn` lines on standard
    # input, the local addresses that listen on PORT on every address of
    # the machine: *, [::] or 0.0.0.0, with or without a device (%eth0).
    # One per line; nothing when there is none.
    local port=${1-}
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    awk -v port="$port" "$BT_WILDCARD_PROGRAM"
}

bt_uplink_verdict() {
    # bt_uplink_verdict NAME ADDRESS PORT LISTENERS PROBE: 3306 is a mesh
    # port, never on the uplink (the manifest of this appliance, expose:
    # mesh). LISTENERS is what `ss -Hltn` printed in the node for PORT,
    # PROBE the exit code of a TCP connection from the host to
    # [ADDRESS]:PORT, the node's address on the bridge, which is its
    # uplink here. A wildcard listener fails even when the probe does not
    # connect, since a firewall can hide it; a probe that connects fails
    # even with no wildcard seen. Exit 2 when an argument is not usable.
    local name=${1-} address=${2-} port=${3-} listeners=${4-} probe=${5-} wildcards
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    case "$probe" in ''|*[!0-9]*) return 2 ;; esac
    [ -n "$name" ] && [ -n "$address" ] || return 2
    wildcards=$(printf '%s\n' "$listeners" | bt_wildcard_listeners "$port" | paste -sd ' ' -)
    if [ -n "$wildcards" ]; then
        echo "boot-test: $name: $port listens on a wildcard address ($wildcards), so it is on the uplink too (keel-mariadb#29)" >&2
        return 1
    fi
    if [ "$probe" -eq 0 ]; then
        echo "boot-test: $name: [$address]:$port answers from the host, on the uplink (keel-mariadb#29)" >&2
        return 1
    fi
    echo "boot-test: $name: $port is not on the uplink [$address]: no wildcard listener, and no answer from the host"
}

bt_spec_targets() {
    # bt_spec_targets ROOTFS: the paths the spec is installed at.
    local relative
    for relative in $BT_SPEC_PATHS; do
        printf '%s/%s\n' "$1" "$relative"
    done
}

bt_spec_in_rootfs() {
    # bt_spec_in_rootfs SPEC ROOTFS: the spec with its secret references
    # pointed inside ROOTFS, printed on stdout. `keel spec apply` runs on
    # the host and resolves a secret path against the host, so the copy it
    # reads has to name the files this test wrote into the container.
    sed -E "s#^([[:space:]]*file:[[:space:]]*)(/etc/keel/secrets/)#\1$2\2#" "$1"
}

bt_random_password() {
    # A fixed block is read first and filtered afterwards. The other way
    # round, "tr < source | head -c N", leaves tr killed by SIGPIPE when
    # head has its N characters, and the set -o pipefail of boot-test.sh
    # turns that into exit 141 before the container is ever started.
    local pool source=${BT_RANDOM_SOURCE:-/dev/urandom}
    pool=$(head -c "$BT_RANDOM_BYTES" "$source" | LC_ALL=C tr -dc 'A-Za-z0-9')
    if [ "${#pool}" -lt "$BT_PASSWORD_LENGTH" ]; then
        echo "boot-test: $source gave only ${#pool} usable characters" >&2
        return 1
    fi
    printf '%s\n' "${pool:0:BT_PASSWORD_LENGTH}"
}

bt_secret_targets() {
    # bt_secret_targets ROOTFS: the secret files the spec references.
    local name
    for name in $BT_SECRETS; do
        printf '%s/etc/keel/secrets/%s\n' "$1" "$name"
    done
}

bt_webmin_verdict() {
    # bt_webmin_verdict CODE: Webmin comes from core and is the panel this
    # layer adds its database module to, so the boot test checks that it
    # answers over IPv6 on 12321. It asks for credentials, so 200 (the
    # login page) and 401 are both an answer; 000 is curl failing to
    # connect at all.
    case "${1-}" in
        200|401)
            echo "boot-test: webmin answered $1 on port $BT_WEBMIN_PORT"
            ;;
        *)
            echo "boot-test: webmin answered '${1-}' on port $BT_WEBMIN_PORT, not 200 or 401" >&2
            return 1
            ;;
    esac
}

bt_module_verdict() {
    # bt_module_verdict PACKAGE STATUS: the Webmin module for this
    # database must be installed on the booted machine, not only in the
    # plan. Batteries included is a property of the distribution, so a
    # panel without its database module is a failed boot test.
    if [ "${2-}" = "install ok installed" ]; then
        echo "boot-test: $1 is installed"
        return 0
    fi
    echo "boot-test: $1 is '${2-}', not 'install ok installed'" >&2
    return 1
}

bt_db_verdict() {
    # bt_db_verdict OUTPUT: what the database client printed when it
    # connected with the declared password and ran the probe query. The
    # whole point of this appliance is that a declared password reaches
    # the database, so the answer is the verdict: anything other than the
    # single row the query asks for means the connection did not happen or
    # did not authenticate.
    local output
    output=$(printf '%s' "${1-}" | tr -d '[:space:]')
    if [ "$output" = "$BT_DB_PROBE_ANSWER" ]; then
        echo "boot-test: $BT_DB_USER authenticated on [$BT_DB_HOST]:$BT_DB_PORT with the declared password"
        return 0
    fi
    echo "boot-test: the database client answered '${1-}', not '$BT_DB_PROBE_ANSWER': the declared password did not reach the database" >&2
    return 1
}

bt_db_diagnostics_argv() {
    # bt_db_diagnostics_argv UNIT: what to ask the container when the
    # database client could not connect at all, one argument per line:
    # the unit's status and the last lines of its journal and of the first
    # boot's, so a server that never came up names its reason in the job's
    # log (status=226/NAMESPACE under a stock LXC profile, a hook that
    # gave up waiting) instead of the client's "Can't connect" alone
    # (run 37842190136 on keel-lxc-1, 2026-10-08). Run through a shell
    # inside the container, since it is two commands.
    local unit=${1-}
    case "$unit" in
        ""|*[!A-Za-z0-9@._-]*) return 1 ;;
    esac
    printf '%s\n' sh -c \
        "systemctl status --no-pager -l $unit; journalctl --no-pager -n $BT_DIAGNOSTIC_LINES -o short-precise -u $unit -u inithooks.service"
}

bt_db_client_argv() {
    # bt_db_client_argv USER HOST PORT: the client command the boot test
    # runs inside the container, one argument per line. The password is
    # not here: it goes through MYSQL_PWD in the environment, so it never
    # appears in the container's process list.
    local user=$1 host=$2 port=$3
    [ -n "$user" ] && [ -n "$host" ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' mysql "--user=$user" "--host=$host" "--port=$port" \
        --protocol=TCP --batch --skip-column-names \
        "--execute=$BT_DB_PROBE_QUERY"
}
bt_diff_verdict() {
    # bt_diff_verdict CODE: interprets the exit code of keel diff
    # (docs/diff.md of the keel repository). 0 and 13 mean no drift.
    case "$1" in
        0) echo "keel diff: no drift"; return 0 ;;
        13) echo "keel diff: no drift, but a declared field could not be observed offline (see the report above)"; return 0 ;;
        14) echo "keel diff: drift found" >&2; return 1 ;;
        2|3) echo "keel diff: the spec is unreadable or invalid (exit $1)" >&2; return 1 ;;
        *) echo "keel diff: failed with exit $1" >&2; return 1 ;;
    esac
}

# --- the replication phase, driven by each node's description --------
#
# What used to be here was hand configuration: a drop-in, two accounts and
# a CHANGE MASTER, each listed in tests/README.md as something the
# appliance would later own. It owns them now. The test writes the role
# into the node's own instance description and runs
# `keel spec apply --system-only`; keel writes the drop-in, grants the
# replication account from the prefix the description names, and starts
# replication. What is left here is the description to write and the
# questions the servers are asked afterwards.

bt_repl_prefix() {
    # bt_repl_prefix ADDRESS: the /64 one node lives on, from its global
    # IPv6 address. The form docs/spec.md of keel tells an operator to
    # prefer, and the one the description carries: with IPv6 and no NAT a
    # fleet's /64 is stable while a list of addresses goes stale on every
    # rebuild. keel turns it into the host pattern MariaDB holds, which is
    # the translation this phase exists to exercise.
    local addr=${1-}
    local -a parts
    if ! bt_is_global_ipv6 "$addr"; then
        echo "boot-test: '$addr' is not a global IPv6 address to authorise" >&2
        return 1
    fi
    IFS=: read -r -a parts <<< "$addr"
    if [ "${#parts[@]}" -lt 4 ] || [ -z "${parts[0]}" ] || [ -z "${parts[1]}" ] \
       || [ -z "${parts[2]}" ] || [ -z "${parts[3]}" ]; then
        echo "boot-test: '$addr' has no written out /64 prefix to authorise" >&2
        return 1
    fi
    printf '%s:%s:%s:%s::/64\n' "${parts[0]}" "${parts[1]}" "${parts[2]}" "${parts[3]}"
}

bt_repl_host_pattern() {
    # bt_repl_host_pattern ADDRESS: the /64 in MariaDB's own spelling. The
    # description never carries this form, keel writes it from the prefix;
    # it is here for the one account row below that is not part of the
    # feature and that this test creates itself.
    local prefix
    prefix=$(bt_repl_prefix "${1-}") || return 1
    printf '%s%%\n' "${prefix%%::/64}:"
}

bt_is_sql_literal() {
    # A value that can go inside single quotes in SQL as it stands. The
    # values this test puts in a statement are ones it generated itself,
    # so anything holding a quote, a backslash or a control character is
    # refused rather than escaped: a test that has to escape is a test
    # building SQL out of something it did not generate. keel escapes,
    # because the credential it handles came from a file it did not write.
    local value=${1-}
    [ -n "$value" ] || return 1
    [[ $value =~ ^[A-Za-z0-9:%._-]+$ ]] || return 1
    return 0
}

bt_repl_section() {
    # bt_repl_section ROLE ADDRESS PEER: the database.server block this
    # node's description gains, appended to tests/instance.yaml, which
    # declares no database section of its own.
    #
    # listen is this node's own loopback pair plus its own global address:
    # a replica cannot reach a primary listening on ::1 only, and opening
    # the port is exactly the decision the console's screens make. PEER is
    # the other node's address: on a primary it becomes the prefix
    # authorised to replicate, on a replica the endpoint replicated from.
    # Neither configures the other machine; each is this node saying what
    # it will accept or where it will look.
    local role=${1-} addr=${2-} peer=${3-} prefix
    if [ "$role" != "$BT_ROLE_PRIMARY" ] && [ "$role" != "$BT_ROLE_REPLICA" ]; then
        echo "boot-test: '$role' is neither $BT_ROLE_PRIMARY nor $BT_ROLE_REPLICA" >&2
        return 1
    fi
    if ! bt_is_global_ipv6 "$addr" || ! bt_is_global_ipv6 "$peer"; then
        echo "boot-test: a node and its peer need global IPv6 addresses" >&2
        return 1
    fi
    printf '%s\n' 'database:'
    printf '%s\n' '  server:'
    printf '%s\n' '    engine: mariadb'
    printf '    role: %s\n' "$role"
    printf '    listen: ["%s", "127.0.0.1", "%s"]\n' "$BT_DB_HOST" "$addr"
    printf '%s\n' '    replication:'
    if [ "$role" = "$BT_ROLE_PRIMARY" ]; then
        prefix=$(bt_repl_prefix "$peer") || return 1
        printf '      allowed_from: ["%s"]\n' "$prefix"
    else
        printf '%s\n' '      primary:'
        printf '        host: "%s"\n' "$peer"
        printf '        port: %s\n' "$BT_DB_PORT"
    fi
    printf '%s\n' '      secret:'
    printf '        file: %s\n' "$BT_REPL_SECRET"
}

bt_apply_verdict() {
    # bt_apply_verdict CODE OUTPUT: what `keel spec apply --system-only`
    # did to the database of one node. 0 is converged; 16 with a refusal
    # in the output is keel declining to do something, which is a
    # different thing from a failure and is quoted rather than summarised.
    local code=${1-} output=${2-} refusal
    refusal=$(printf '%s' "$output" | sed -n "s/.*$BT_REPL_REFUSED//p" | head -1)
    if [ "$code" = 0 ]; then
        echo "boot-test: keel converged the declared role"
        return 0
    fi
    if [ "$code" = "$BT_APPLY_FAILED" ] && [ -n "$refusal" ]; then
        echo "boot-test: keel refused: $refusal" >&2
        return 1
    fi
    echo "boot-test: keel spec apply --system-only failed with exit $code" >&2
    return 1
}

bt_refusal_verdict() {
    # bt_refusal_verdict CODE OUTPUT: the other way round. Here the
    # refusal is what is being proved, so a run that went ahead and
    # configured the replica is the failure. This is the one property of
    # the feature that loses data if it is wrong (handbook decision 0013),
    # so the gate asserts it on a real server and not only in unit tests.
    #
    # A refusal for another reason is not this one, and is quoted: keel
    # refuses a replica whose primary does not answer as the replication
    # account before it looks at the data, so a run that asks this before
    # the primary has converged gets that refusal and proves nothing about
    # the data (run 37838543320, 2026-10-08). The main converges the
    # primary first for that reason, and this line says what happened when
    # the order is wrong again.
    local code=${1-} output=${2-} refusal
    if [ "$code" != "$BT_APPLY_FAILED" ]; then
        echo "boot-test: apply exited $code over a database that holds data; it must refuse" >&2
        return 1
    fi
    case "$output" in
        *"$BT_REPL_REFUSED"*"$BT_REPL_HELD_DB"*)
            echo "boot-test: keel refused to replace the database this server holds"
            return 0 ;;
    esac
    refusal=$(printf '%s' "$output" | sed -n "s/.*$BT_REPL_REFUSED//p" | head -1)
    if [ -n "$refusal" ]; then
        echo "boot-test: apply exited $code but said nothing about $BT_REPL_HELD_DB; it refused for another reason: $refusal" >&2
    else
        echo "boot-test: apply exited $code but said nothing about $BT_REPL_HELD_DB, and gave no refusal at all" >&2
    fi
    return 1
}

# The step the run is in, for the one line the teardown adds to a failure:
# the job's log then names the phase and the step that failed instead of
# ending on the last command's own words.
BT_STEP=""

bt_step() {
    # bt_step NAME TEXT: records the step the run is in as "NAME, TEXT";
    # refuses an empty name or text, since a failure that names nothing is
    # what this exists to prevent. Run it in the shell that keeps BT_STEP,
    # not in a command substitution.
    local name=${1-} text=${2-}
    if [ -z "$name" ] || [ -z "$text" ]; then
        echo "boot-test: a step needs a name and a text" >&2
        return 1
    fi
    BT_STEP="$name, $text"
}

bt_step_failed() {
    # bt_step_failed CODE STEP: the failure line, when there is a failure
    # and a step to name. Nothing on exit 0, nothing before the first step.
    local code=${1-} step=${2-}
    if [ "$code" = 0 ] || [ -z "$step" ]; then
        return 1
    fi
    printf 'boot-test: FAILED (exit %s) in step %s\n' "$code" "$step"
}

bt_dropin_verdict() {
    # bt_dropin_verdict ROLE TEXT: the drop-in keel says it wrote. Read
    # back because a file a command claims to have written is a file that
    # has to be there, and because the binary log is what tells a primary
    # from a replica in that file.
    local role=${1-} text=${2-}
    if [[ $text != *"server_id = "* ]]; then
        echo "boot-test: the drop-in names no server id" >&2
        return 1
    fi
    case "$role:$text" in
        "$BT_ROLE_PRIMARY:"*log_bin*)
            echo "boot-test: the primary has a binary log a replica can read"
            return 0 ;;
        "$BT_ROLE_PRIMARY:"*)
            echo "boot-test: the primary has no binary log" >&2; return 1 ;;
        "$BT_ROLE_REPLICA:"*log_bin*)
            echo "boot-test: the replica was given a binary log it does not need" >&2
            return 1 ;;
    esac
    echo "boot-test: the replica needs no binary log of its own"
    return 0
}

bt_keel_deb_argv() {
    # bt_keel_deb_argv NAME: how a locally built keel is installed into a
    # node that has already booted (--keel-deb). The gate never passes it:
    # there the keel under test is the one the published layer carries,
    # which is the whole point of assembling a published layer. It is for
    # the maintainer proving a keel before the layer that carries it is
    # published, which is the order this feature had to be done in.
    local name=${1-}
    case "$name" in
        ""|*/*|*[!A-Za-z0-9._+-]*)
            echo "boot-test: '$name' is not a package file name" >&2
            return 1 ;;
    esac
    printf '%s\n' dpkg --install "/root/$name"
}

bt_repl_admin_sql() {
    # bt_repl_admin_sql USER HOST PASSWORD: a host row for the
    # administrative account on the replica. The one statement this phase
    # still issues by hand, and it is not part of the replication feature:
    # it exists only so the proof below can be read from the other machine
    # by an account the description declares, rather than by something the
    # test invented. Idempotent, so a retry passes.
    #
    # SELECT on the one database, and deliberately not ALL PRIVILEGES.
    # ALL includes Repl_slave_priv, so an administrative account reachable
    # from a prefix is an authorization to replicate from that prefix, and
    # `keel inspect` reads the machine as a primary because that is what
    # the machine is. apply then refuses to demote it, correctly, and the
    # replica is never built. Measured on the build host 2026-09-27, and
    # the fix is to grant what the test needs and nothing more.
    local user=${1-} host=${2-} password=${3-}
    if ! bt_is_sql_literal "$user" || ! bt_is_sql_literal "$host" \
       || ! bt_is_sql_literal "$password"; then
        echo "boot-test: an account needs a plain user, host and password" >&2
        return 1
    fi
    cat <<SQL
CREATE USER IF NOT EXISTS '$user'@'$host' IDENTIFIED BY '$password';
ALTER USER '$user'@'$host' IDENTIFIED BY '$password';
GRANT SELECT ON $BT_REPL_DB.* TO '$user'@'$host';
FLUSH PRIVILEGES;
SQL
}

bt_held_db_sql() {
    # The database the operator is supposed to be warned about, created on
    # the node that is about to be told to become a replica.
    printf 'CREATE DATABASE IF NOT EXISTS %s;\n' "$BT_REPL_HELD_DB"
}

bt_drop_held_db_sql() {
    printf 'DROP DATABASE IF EXISTS %s;\n' "$BT_REPL_HELD_DB"
}

bt_repl_write_sql() {
    # bt_repl_write_sql MARKER: the row written on the primary. One row with
    # a value generated for this run, so reading it anywhere else can only
    # mean it travelled.
    local marker=${1-}
    if ! bt_is_sql_literal "$marker" \
       || [ "${#marker}" -gt "$BT_REPL_MARKER_MAX" ]; then
        echo "boot-test: '$marker' is not a marker this test writes" >&2
        return 1
    fi
    cat <<SQL
CREATE DATABASE IF NOT EXISTS $BT_REPL_DB;
CREATE TABLE IF NOT EXISTS $BT_REPL_DB.$BT_REPL_TABLE (
    id INT PRIMARY KEY, marker VARCHAR(64) NOT NULL);
REPLACE INTO $BT_REPL_DB.$BT_REPL_TABLE (id, marker) VALUES (1, '$marker');
SQL
}

bt_repl_read_query() {
    # The query the replica is asked, from the other node.
    printf 'SELECT marker FROM %s.%s WHERE id = 1\n' "$BT_REPL_DB" "$BT_REPL_TABLE"
}

bt_repl_running_verdict() {
    # bt_repl_running_verdict OUTPUT: what the replica answered to
    # "SHOW GLOBAL STATUS LIKE 'Slave_running'", which is "Slave_running"
    # and a value. The server is asked what it thinks it is rather than the
    # configuration being read back, which is the trap docs/traps.md names
    # "asserting the configuration is not asserting the behaviour".
    local value
    value=$(printf '%s' "${1-}" | awk 'NR == 1 { print $2 }')
    if [ "$value" = "$BT_REPL_RUNNING_ANSWER" ]; then
        echo "boot-test: the replica reports Slave_running $value"
        return 0
    fi
    echo "boot-test: the replica reports Slave_running '${value:-nothing}', not $BT_REPL_RUNNING_ANSWER" >&2
    return 1
}

bt_repl_row_verdict() {
    # bt_repl_row_verdict EXPECTED OUTPUT: the row the replica returned,
    # compared with what was written on the primary. This is the whole
    # point: the value was generated on the host, written on one machine
    # and read from another over IPv6, so equality is the proof that
    # replication carried it and nothing else could have.
    local expected=${1-} got
    got=$(printf '%s' "${2-}" | tr -d '[:space:]')
    if [ -n "$expected" ] && [ "$got" = "$expected" ]; then
        echo "boot-test: the replica returned the row written on the primary ($got)"
        return 0
    fi
    echo "boot-test: the replica returned '$got', not the row written on the primary ('$expected')" >&2
    return 1
}

bt_db_argv() {
    # bt_db_argv USER HOST PORT QUERY: the client command for a query this
    # test chooses, one argument per line, for a caller that runs it with
    # lxc-attach. bt_db_client_argv above is the fixed probe of the single
    # node test and stays as it is; this is the same shape with the query
    # given. The password is never here: it goes through MYSQL_PWD.
    local user=${1-} host=${2-} port=${3-} query=${4-}
    [ -n "$user" ] && [ -n "$host" ] && [ -n "$query" ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' mysql "--user=$user" "--host=$host" "--port=$port" \
        --protocol=TCP --batch --skip-column-names "--execute=$query"
}
