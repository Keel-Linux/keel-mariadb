#!/bin/bash
# Logic behind firstboot.d/35mysqlpass (decision 0004: logic apart from
# effect). Meant to be sourced. Every function reads its inputs from its
# arguments, prints its result on stdout and returns non-zero instead of
# exiting, so the hook decides what is fatal and a test can exercise every
# branch without a database, a network or root.

# The administrative account of this layer. Upstream names it after Adminer
# and creates it in common's conf/adminer-mysql; this layer has no Adminer,
# so it owns the account and the name is its own.
MARIADB_ADMIN_USER="${MARIADB_ADMIN_USER:-admin}"
# Where that account may authenticate from. MariaDB matches a socket
# connection against the host 'localhost' and a TCP connection against the
# literal address, so the three are three separate accounts. IPv6 first.
MARIADB_ADMIN_HOSTS="${MARIADB_ADMIN_HOSTS:-localhost ::1 127.0.0.1}"
MARIADB_VERIFY_HOST="${MARIADB_VERIFY_HOST:-::1}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_SERVICE="${MARIADB_SERVICE:-mariadb}"
MARIADB_WAIT_TRIES="${MARIADB_WAIT_TRIES:-30}"
# What a MariaDB account name may be here. MariaDB allows far more, but a
# name that needs quoting in a GRANT is a name this layer will not create.
MARIADB_USER_RE='^[A-Za-z_][A-Za-z0-9_-]*$'

# mariadb_first_value VALUE...: the first argument that is set and is not
# the inithooks placeholder DEFAULT; fails when there is none.
mariadb_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            echo "$value"
            return 0
        fi
    done
    return 1
}

# mariadb_admin_user [APP_DB_USER]: the account the password belongs to.
# app.options.db_user of the instance description renders to APP_DB_USER,
# so an appliance above this layer can name its own account without
# patching the hook.
mariadb_admin_user() {
    local name
    name=$(mariadb_first_value "${1-}" "$MARIADB_ADMIN_USER")
    mariadb_is_user_name "$name" || return 1
    echo "$name"
}

# mariadb_is_user_name NAME: true for a name this layer will put in a GRANT
mariadb_is_user_name() {
    [[ -n "${1-}" ]] && [[ $1 =~ $MARIADB_USER_RE ]]
}

# mariadb_admin_hosts: the hosts the account is configured for, one per line
mariadb_admin_hosts() {
    local host
    for host in $MARIADB_ADMIN_HOSTS; do
        printf '%s\n' "$host"
    done
}

# mariadb_missing_values PASS: the names of the values that need a prompt.
# Empty output means the instance description carried everything, which is
# the headless case the boot test proves.
mariadb_missing_values() {
    [[ -n "${1-}" ]] || echo DB_PASS
    return 0
}

# mariadb_conf_args USER HOST PASS: the argument list for bin/mysqlconf.py,
# one argument per line. Fails on an empty password rather than letting
# mysqlconf.py open a dialog, because a hook that prompts on a headless
# first boot hangs the boot.
mariadb_conf_args() {
    local user=$1 host=$2 pass=$3
    mariadb_is_user_name "$user" || return 1
    [[ -n "$host" ]] || return 1
    [[ -n "$pass" ]] || return 1
    printf '%s\n' "--user=$user" "--host=$host" "--pass=$pass"
}

# mariadb_verify_args USER HOST PORT: the argument list for the client call
# that proves the password works, one argument per line. The password is
# not among them: it goes to the client on stdin through --defaults-file or
# the MYSQL_PWD environment, never on a command line another process can
# read.
mariadb_verify_args() {
    local user=$1 host=$2 port=$3
    mariadb_is_user_name "$user" || return 1
    [[ -n "$host" ]] || return 1
    [[ $port =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "--user=$user" "--host=$host" "--port=$port" \
        "--protocol=TCP" "--batch" "--skip-column-names" \
        "--execute=SELECT 1"
}

# mariadb_wait_ready COMMAND TRIES: run COMMAND until it succeeds, once a
# second, up to TRIES times. COMMAND is given so a test can pass its own.
mariadb_wait_ready() {
    local command=$1 tries=$2 attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if $command >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        ${MARIADB_SLEEP:-sleep} 1
    done
    return 1
}

# mariadb_masked PASS: what the log may show of a password
mariadb_masked() {
    if [[ -z "${1-}" ]]; then
        echo "(none)"
    else
        echo "(${#1} characters)"
    fi
}
