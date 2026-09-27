#!/bin/bash
# Boot test of this layer (org-plan section 1): assemble the published layer
# chain into an LXC rootfs, boot it headless from tests/instance.yaml, wait
# for the first boot to finish, then prove the declarative path end to end.
# The instance description declares secrets.db_password from a file; nothing
# is configured by hand; and the test connects to the database as a client,
# with that password, to say whether it arrived. A listening port would prove
# nothing here: the database listens whatever password it ended up with.
#
# It also checks what the panel offers, because batteries included is a
# property of this distribution: the Webmin module for this database is
# installed and Webmin answers over IPv6 on 12321.
#
# With --roles it does all of the above on one container per role, on the
# same bridge, and then runs the replication phase. That phase configures
# nothing by hand: it writes each node's role into that node's own instance
# description and runs `keel spec apply --system-only`, which is what the
# console's Primary and Replica screens call, and then asserts the outcome.
# It also proves the refusal, on a real server: a replica that would replace
# a database the operator put there is declined and nothing is changed.
# Handbook decision 0013 made a test like this the condition for building
# the feature at all; tests/README.md lists what is left of hand
# configuration, which is one account row that is not part of the feature.
#
# Called by the reusable workflow test-appliance.yml after keel pull and
# keel verify; runnable by hand as root on any host with LXC, see
# tests/README.md. It builds nothing: the layers come from the mirror or
# from a directory bt-layer wrote, so the test needs no fab, deck or
# buildtasks. The logic lives in tests/lib/boot-test-lib.sh and, for the
# topology, in lib/boot-test-nodes.sh of keel-linux/.github; both are unit
# tested, and this file is the thin main that touches the system.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() {
    local command=$1 container=$2
    shift 2
    "lxc-$command" -P "$BT_LXC_PATH" -n "$container" "$@"
}
node_dir() { printf '%s/%s\n' "$BT_LXC_PATH" "$1"; }
node_rootfs() { printf '%s/%s/rootfs\n' "$BT_LXC_PATH" "$1"; }

# --- the topology -----------------------------------------------------
#
# One node unless --roles asks for more, and then one container per role,
# with the names lib/boot-test-nodes.sh derives: the workflow's teardown and
# its job summary derive the same ones from the same function. With one node
# the container is BT_NAME itself and nothing about this run differs from
# what it has always been.
if [ -n "$BT_ROLES" ]; then
    [ -r "$BT_NODES_LIB" ] || {
        echo "boot-test: cannot read $BT_NODES_LIB (--nodes-lib)" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source "$BT_NODES_LIB"
    nodes=$(btn_nodes "$BT_NAME" "$BT_ROLES")
else
    nodes="1 $BT_NAME solo"
fi
names=()
roles=()
while read -r index name role; do
    names+=("$name")
    roles+=("$role")
done <<< "$nodes"
node_count=${#names[@]}

secrets_dir=$(mktemp -d)

cleanup() {
    local rc=$? container hooks
    if [ "$rc" -ne 0 ]; then
        for container in "${names[@]}"; do
            hooks=$(node_rootfs "$container")/var/log/inithooks.log
            if [ -r "$hooks" ]; then
                log "last lines of $container's inithooks log:"
                tail -n 40 "$hooks"
            fi
        done
    fi
    rm -rf "$secrets_dir"
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping ${names[*]} under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n ${names[0]}"
        return
    fi
    # Every node is stopped before any tree is removed. The other order
    # takes the configuration of a still running container out from under
    # it and leaves its init process alive on a rootfs that no longer
    # exists: two containers left behind on a shared host cost somebody
    # else a debugging session.
    for container in "${names[@]}"; do
        lxc stop "$container" -k >/dev/null 2>&1 || true
    done
    for container in "${names[@]}"; do
        rm -rf "$(node_dir "$container")"
    done
}
# EXIT covers the normal end and every failure. The other two turn a signal
# into an exit, so a cancelled run tears down here too rather than relying
# only on the workflow's own teardown step, which is the second line.
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT
trap 'log "terminated"; exit 143' TERM

# --- 1. the layers, pulled once for the whole run ---------------------
log "pulling $BT_APPLIANCE from $BT_LAYERS_DIR"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive

# --- 2. the secrets of this run ---------------------------------------
#
# One set of values for every node. A replica is a copy of its primary, so
# both machines hold the same declared description and therefore the same
# secret files, which is also what an operator would deploy.
install -d -m 0700 "$secrets_dir"
for secret in $BT_SECRETS; do
    bt_random_password > "$secrets_dir/$secret"
    chmod 0600 "$secrets_dir/$secret"
done
declared_password=$(cat "$secrets_dir/db_password")
repl_password=$(cat "$secrets_dir/app_password")

# --- 3. assemble, mark, describe and configure each node --------------
prepare_node() {
    # prepare_node INDEX NAME ROLE
    local index=$1 container=$2 role=$3 dir rootfs target
    dir=$(node_dir "$container")
    rootfs=$(node_rootfs "$container")
    log "assembling $BT_APPLIANCE into $rootfs ($role)"
    lxc stop "$container" -k >/dev/null 2>&1 || true
    rm -rf "$dir"
    mkdir -p "$rootfs"
    keel assemble "$BT_APPLIANCE" --rootfs "$rootfs" \
        --cache-dir "$BT_CACHE_DIR" --non-interactive
    # bt_mark_container does what buildtasks' container patch does: the
    # marker under /var/lib/turnkey-info that inspect reads to call the
    # machine a container (managed_by: host), and REDIRECT_OUTPUT=true with
    # a drop-in, without which a hook that prints more than the terminal
    # buffer holds blocks writing to a tty1 nobody reads.
    bt_mark_container "$rootfs"
    install -d -m 0700 "$rootfs/etc/keel/secrets"
    for target in $(bt_secret_targets "$rootfs"); do
        install -m 0600 "$secrets_dir/$(basename "$target")" "$target"
    done
    for target in $(bt_spec_targets "$rootfs"); do
        install -D -m 0600 "$BT_SPEC" "$target"
    done
    # The conf is what makes the first boot headless; without it 30rootpass
    # and 35mysqlpass wait on a dialog forever.
    bt_spec_in_rootfs "$BT_SPEC" "$rootfs" > "$dir/instance-host.yaml"
    keel spec apply --spec "$dir/instance-host.yaml" \
        --conf "$rootfs/etc/inithooks.conf" --non-interactive
    # How a node learns which one it is: a file in its own filesystem, the
    # way every other appliance setting arrives. The instance description
    # cannot carry the role yet (decision 0013, phase 2), which is exactly
    # why the test writes this and why it is listed as hand configuration.
    if [ -n "$BT_ROLES" ]; then
        btn_node_env "$index" "$container" "$role" "$node_count" \
            > "$rootfs/$BTN_NODE_ENV"
        chmod 0644 "$rootfs/$BTN_NODE_ENV"
    fi
    # The apparmor pair in bt_lxc_config is what lets systemd give a unit a
    # mount namespace. mariadb.service has ProtectSystem=full and
    # ProtectHome=true, so without it the database fails with status=226
    # before its own first line runs.
    bt_lxc_config "$container" "$rootfs" "$BT_BRIDGE" > "$dir/config"
}

for ((i = 0; i < node_count; i++)); do
    prepare_node "$((i + 1))" "${names[i]}" "${roles[i]}"
done

# --- 4. boot them all, then wait for an address each ------------------
for container in "${names[@]}"; do
    log "starting $container on bridge $BT_BRIDGE"
    lxc start "$container" -d
done

addrs=()
for container in "${names[@]}"; do
    bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $container" \
        bt_container_ipv6 "$container" "$BT_LXC_PATH" > /dev/null
    addr=$(bt_container_ipv6 "$container" "$BT_LXC_PATH")
    addrs+=("$addr")
    log "$container has the address $addr"
done

# --- 5. the topology, reported and handed to every node ---------------
topology=""
for ((i = 0; i < node_count; i++)); do
    topology+="$((i + 1)) ${names[i]} ${roles[i]} ${addrs[i]}"$'\n'
done
node_addr() { awk -v want="$1" '$2 == want { print $4 }' <<< "$topology"; }
node_index() { awk -v want="$1" '$2 == want { print $1 }' <<< "$topology"; }
node_role() { awk -v want="$1" '$2 == want { print $3 }' <<< "$topology"; }

if [ -n "$BT_ROLES" ]; then
    if [ -n "$BT_NODES_REPORT" ]; then
        printf '%s' "$topology" > "$BT_NODES_REPORT"
        chmod 0644 "$BT_NODES_REPORT"
        log "topology reported in $BT_NODES_REPORT"
    fi
    # Now that every node has an address, every node is told all of them.
    peers=$(btn_peers_env "$topology")
    for container in "${names[@]}"; do
        printf '%s\n' "$peers" > "$(node_rootfs "$container")/$BTN_PEERS_ENV"
        chmod 0644 "$(node_rootfs "$container")/$BTN_PEERS_ENV"
    done
    log "every node holds the peers file; addresses literal and IPv6"
fi

# --- 6. first boot finished on every node -----------------------------
#
# 98finalize has cleared RUN_FIRSTBOOT and the machine answers, on the
# console (confconsole's usage screen) or on SSH. The answer alone is not
# enough: sshd is up long before the hooks are done, so the flag is what
# says the first boot ended.
usage_screen() {
    lxc attach "$1" -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$1" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    # first_boot_done NAME ADDRESS
    bt_firstboot_done_in "$(node_rootfs "$1")/etc/default/inithooks" || return 1
    usage_screen "$1" || ssh_answers "$2"
}
for ((i = 0; i < node_count; i++)); do
    bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of ${names[i]} to finish" \
        first_boot_done "${names[i]}" "${addrs[i]}"
    log "first boot of ${names[i]} finished; ssh root@${addrs[i]}"
done

# A keel no published layer carries yet (--keel-deb). The gate never
# passes it: there the keel under test is the one the layer carries. The
# first boot has already run, and it converged a description with no
# database section, so nothing it did depended on which keel this is.
if [ -n "$BT_KEEL_DEB" ]; then
    mapfile -t install_keel < <(bt_keel_deb_argv "$(basename "$BT_KEEL_DEB")")
    for container in "${names[@]}"; do
        install -m 0644 "$BT_KEEL_DEB" "$(node_rootfs "$container")/root/"
        lxc attach "$container" -- "${install_keel[@]}"
        log "$container: $(lxc attach "$container" -- keel --version)"
    done
fi

# --- 7. what every node is, checked on every node ---------------------
code=""
webmin_answers() {
    code=$(curl -6 -k -s -o /dev/null -w '%{http_code}' \
        "https://[$1]:$BT_WEBMIN_PORT/" || true)
    [ "$code" = 200 ] || [ "$code" = 401 ]
}
for ((i = 0; i < node_count; i++)); do
    container=${names[i]}
    addr=${addrs[i]}
    log "--- $container, ${roles[i]}, at $addr"

    # What the first boot hook reported, quoted here so a failure below is
    # read next to it.
    grep -E '35mysqlpass|MariaDB' \
        "$(node_rootfs "$container")/var/log/inithooks.log" || true

    # The declarative path, end to end: a client connection to the database
    # with the password the description declared. The client runs inside the
    # container over TCP on [::1], because the layer's database listens on
    # loopback only, and the password reaches it in the environment so it
    # never appears in the container's process list.
    mapfile -t client < <(bt_db_client_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT")
    answer=$(lxc attach "$container" --set-var "MYSQL_PWD=$declared_password" -- "${client[@]}") \
        || { echo "boot-test: the database on $container refused the declared password" >&2; exit 1; }
    bt_db_verdict "$answer"

    # The panel core carries, with the module this layer adds to it.
    status=$(lxc attach "$container" -- dpkg-query -W -f '${Status}' "$BT_WEBMIN_MODULE" 2>/dev/null || true)
    bt_module_verdict "$BT_WEBMIN_MODULE" "$status"
    bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "webmin on https://[$addr]:$BT_WEBMIN_PORT/" \
        webmin_answers "$addr"
    bt_webmin_verdict "$code"

    # No drift between the declared description and the booted root. This
    # runs before the replication phase on purpose: that phase writes a
    # MariaDB drop-in the description says nothing about, which is drift by
    # design and the class of problem decision 0013 lists under promotion.
    set +e
    keel diff --root "$(node_rootfs "$container")" --spec "$BT_SPEC"
    diff_code=$?
    set -e
    bt_diff_verdict "$diff_code"
done

if [ -z "$BT_ROLES" ]; then
    log "$BT_APPLIANCE boot test passed on one node"
    exit 0
fi

# --- 8. the replication phase, configured by keel from the descriptions
#
# Nothing here writes a MariaDB setting, creates an account or issues a
# CHANGE MASTER. The test writes each node's role into that node's own
# instance description and runs `keel spec apply --system-only` on it,
# which is what the console's Primary and Replica screens do. What is
# asserted afterwards is the outcome: what the servers say they are, and a
# row written on one turning up on the other.
primary=$(btn_role_node "$topology" "$BT_ROLE_PRIMARY")
replica=$(btn_role_node "$topology" "$BT_ROLE_REPLICA")
primary_addr=$(node_addr "$primary")
replica_addr=$(node_addr "$replica")
primary_pattern=$(bt_repl_host_pattern "$primary_addr")
log "replication phase: primary $primary [$primary_addr], replica $replica [$replica_addr]"

apply_output=""
apply_code=0
apply_node() {
    # apply_node NAME: converge that node's description from the machine
    # itself, the way the first boot hook and the console both do. The
    # output and the exit code go in apply_output and apply_code, because
    # a refusal is one of the things this phase asserts and a refusal is
    # a non zero exit under `set -e`.
    apply_code=0
    set +e
    apply_output=$(lxc attach "$1" -- \
        keel spec apply --system-only --non-interactive 2>&1)
    apply_code=$?
    set -e
    printf '%s\n' "$apply_output"
}

# 8a. Each node's description gains its own database.server section: its
#     role, the addresses it answers on, and either the prefix it
#     authorises (primary) or the endpoint it replicates from (replica).
#     Written into both paths the first boot reads, so the description on
#     the machine is the description keel acts on.
for pair in "$primary $replica" "$replica $primary"; do
    read -r container peer <<< "$pair"
    rootfs=$(node_rootfs "$container")
    section=$(bt_repl_section "$(node_role "$container")" \
        "$(node_addr "$container")" "$(node_addr "$peer")")
    for target in $(bt_spec_targets "$rootfs"); do
        printf '\n%s\n' "$section" >> "$target"
    done
    log "$container: description now declares $(node_role "$container")"
done

# 8b. The refusal, proved on a real server before anything is configured.
#     The replica is given a database of its own first. Becoming a replica
#     replaces it, so keel must refuse and change nothing; this is the one
#     property of the feature that loses data if it is wrong, and decision
#     0013 is the reason it is asserted here and not only in unit tests.
bt_held_db_sql | lxc attach "$replica" -- mysql
log "$replica: holds the database $BT_REPL_HELD_DB, which a replica would replace"
apply_node "$replica"
bt_refusal_verdict "$apply_code" "$apply_output"
still=$(lxc attach "$replica" -- mysql --batch --skip-column-names \
    --execute="$BT_REPL_RUNNING_QUERY" | awk 'NR == 1 { print $2 }')
if [ "$still" = "$BT_REPL_RUNNING_ANSWER" ]; then
    echo "boot-test: the refused run started replication anyway" >&2
    exit 1
fi
log "$replica: nothing was configured, $BT_REPL_HELD_DB is untouched"
bt_drop_held_db_sql | lxc attach "$replica" -- mysql

# 8c. The primary first: it must hold its authorization and its binary log
#     before the replica connects.
apply_node "$primary"
bt_apply_verdict "$apply_code" "$apply_output"
dropin=$(lxc attach "$primary" -- cat "/$BT_REPL_CNF")
printf '%s\n' "$dropin"
bt_dropin_verdict "$BT_ROLE_PRIMARY" "$dropin"

# 8d. Each node's database answers from the other one, over IPv6, at a
#     literal address. Until this passes, nothing about a pair of machines
#     can be asserted at all.
for pair in "$primary $replica $replica_addr" "$replica $primary $primary_addr"; do
    read -r from to to_addr <<< "$pair"
    mapfile -t probe < <(btn_tcp_probe_argv "$to_addr" "$BT_DB_PORT")
    bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" \
        "$to to answer on [$to_addr]:$BT_DB_PORT from $from" \
        lxc attach "$from" -- "${probe[@]}"
    log "$from reaches $to on [$to_addr]:$BT_DB_PORT"
done

# 8e. A host row for the administrative account on the replica. The one
#     piece of hand configuration left, and it is not part of the feature:
#     it exists only so the proof below can be read from the other machine
#     by an account the description declares.
bt_repl_admin_sql "$BT_DB_USER" "$primary_pattern" "$declared_password" \
    | lxc attach "$replica" -- mysql
log "$replica: '$BT_DB_USER'@'$primary_pattern' may read it"

# 8f. Now the replica, over a database that holds nothing.
apply_node "$replica"
bt_apply_verdict "$apply_code" "$apply_output"
dropin=$(lxc attach "$replica" -- cat "/$BT_REPL_CNF")
printf '%s\n' "$dropin"
bt_dropin_verdict "$BT_ROLE_REPLICA" "$dropin"

# 8g. Ask the servers what they are, rather than reading back the files
#     keel wrote (docs/traps.md, "asserting the configuration is not
#     asserting the behaviour").
running=""
replication_running() {
    running=$(lxc attach "$replica" -- mysql --batch --skip-column-names \
        --execute="$BT_REPL_RUNNING_QUERY" 2>/dev/null) || return 1
    [ "$(printf '%s' "$running" | awk 'NR == 1 { print $2 }')" = "$BT_REPL_RUNNING_ANSWER" ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "$replica to report replication running" \
    replication_running
bt_repl_running_verdict "$running"

granted=$(lxc attach "$primary" -- mysql --batch --skip-column-names \
    --execute="SELECT Host FROM mysql.user WHERE User = '$BT_REPL_USER'")
log "$primary: '$BT_REPL_USER' is granted from $(printf '%s' "$granted" | tr '\n' ' ')"

# 8h. No drift on either node: the description says what the machines are,
#     which is the whole claim of this phase. It runs here and not before,
#     because before the apply the descriptions declared a role neither
#     machine was in yet.
for container in "$primary" "$replica"; do
    set +e
    lxc attach "$container" -- keel diff
    diff_code=$?
    set -e
    bt_diff_verdict "$diff_code"
done

# 8i. Write on the primary, read on the replica. The value is generated on
#     the host for this run alone, written on one machine by the
#     administrative account with its declared password and read back from
#     the other machine over IPv6, so the same value appearing there can
#     only mean replication carried it.
marker=$(bt_random_password)
mapfile -t writer < <(bt_db_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT" \
    "$(bt_repl_write_sql "$marker" | tr '\n' ' ')")
lxc attach "$primary" --set-var "MYSQL_PWD=$declared_password" -- "${writer[@]}"
log "$primary: wrote $BT_REPL_DB.$BT_REPL_TABLE over [$BT_DB_HOST]"

mapfile -t reader < <(bt_db_argv "$BT_DB_USER" "$replica_addr" "$BT_DB_PORT" \
    "$(bt_repl_read_query)")
row=""
row_reached_replica() {
    row=$(lxc attach "$primary" --set-var "MYSQL_PWD=$declared_password" \
        -- "${reader[@]}" 2>/dev/null) || return 1
    [ -n "$(printf '%s' "$row" | tr -d '[:space:]')" ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" \
    "the row written on $primary to arrive on $replica" row_reached_replica
bt_repl_row_verdict "$marker" "$row"
log "read from $primary against [$replica_addr]:$BT_DB_PORT as $BT_DB_USER"

log "$BT_APPLIANCE boot test passed on $node_count nodes, replication included"
