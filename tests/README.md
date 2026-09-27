# Tests

What a test means for a layer recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot
completes headless from an instance description, the database accepts the
password that description declared, the panel has the module for it, and
the machine matches the description.

## Layout

- `boot-test.sh`: the boot test. `test-appliance.yml` (reusable workflow of
  `keel-linux/.github`) runs it on the self-hosted LXC runner after pulling
  the layers from `https://mirror.keellinux.org/layers` and checking them
  with `keel verify`. It is the thin main: assemble, mark the tree as a
  container, install the description, the secrets and the conf, start the
  container, wait, connect to the database, check Webmin, `keel diff`. It
  builds nothing, so it needs no fab, deck or buildtasks.
- `lib/boot-test-lib.sh`: the logic (argument parsing, address discovery
  from `lxc-info`, waiting with a deadline, the secret files, the client
  call, the database, module and Webmin verdicts, the diff verdict, and the
  replication phase's drop-in, accounts, statements and verdicts), as
  functions with no side effects, per decision 0004. Same shape as the one
  in keel-core and keel-nodebb.
- The topology of a run with several nodes is not here: it is
  `lib/boot-test-nodes.sh` of `keel-linux/.github`, which the reusable
  workflow clones and passes with `--nodes-lib`, and which is unit tested
  and measured in that repository. It is shared rather than copied because
  four copies of a boot test library is the trap `docs/traps.md` ends with.
- `boot-test.bats`: unit tests of that library. `lxc-info` is a stub first
  in `PATH`; the clock and `sleep` are functions. No root, no network, no
  LXC, no database.
- `mariadb.bats`: unit tests of
  `overlay/usr/lib/inithooks/lib/mariadb.sh`, the logic behind the first
  boot hook `35mysqlpass`.
- `hook.bats`: the hook itself, run for real against scratch directories
  with every system command stubbed.
- `coverage.sh`: runs the bats suite under kcov and fails when any measured
  file is below `COVERAGE_THRESHOLD` (default 95).
- `instance.yaml`: the description the test container boots from. It
  declares `secrets.db_password` from a file, which is the point of the
  test.

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/mariadb.bats
    bats tests/hook.bats
    bats tests/boot-test.bats
    COVERAGE_THRESHOLD=95 tests/coverage.sh

`COVERAGE_DIR=coverage tests/coverage.sh` keeps the kcov reports.

## The boot test by hand

Needs root, `keel` on `PATH`, LXC (`lxc-start`, `lxc-info`, `lxc-attach`,
`lxc-stop`), `curl`, and a bridge with IPv6 router advertisements or
DHCPv6.

    tests/boot-test.sh mariadb --layers-dir https://mirror.keellinux.org/layers \
        --bridge lxcbr0

`--layers-dir` is a directory or an http(s) URL, so on the build host it is
`/mnt/builds/layers` and on a runner it is the mirror. The other useful
options are `--bridge`, `--cache-dir`, `--lxc-path`, `--name`, `--timeout`
and `--keep` (leaves the container running; then `lxc-attach -n <name>`).
`tests/boot-test.sh --help` lists them all.

What it does, in order:

1. `keel pull` and `keel assemble` the chain (core, mariadb) into
   `<lxc-path>/<name>/rootfs`.
2. Marks the tree as a container build, which is what `bt_mark_container`
   does and what buildtasks' `patches/container/conf` does for a real
   container image: the marker
   `var/lib/turnkey-info/inithooks.service/lxc` that `keel inspect` reads
   to call the machine a container (`network.managed_by: host`),
   `REDIRECT_OUTPUT=true` in `etc/default/inithooks`, and a drop-in giving
   `inithooks.service` `StandardOutput=journal`. Without the last two the
   hooks write to `/dev/tty1`, which nobody reads in a container, and the
   first hook that prints more than the terminal buffer holds blocks there
   forever.
3. Writes a random `root_password` and `db_password` under
   `etc/keel/secrets` (mode 0600) and installs `tests/instance.yaml` at
   `etc/keel/instance.yaml` and `etc/inithooks.yaml`.
4. Renders the description into the rootfs `etc/inithooks.conf` with
   `keel spec apply`, from a copy whose secret references point inside the
   rootfs. Without the conf the first boot is not headless: `30rootpass`
   and `35mysqlpass` would have nothing declared and no terminal.
5. Writes an LXC config for that rootfs on the bridge and starts the
   container. The config asks for `lxc.apparmor.profile = generated` and
   `lxc.apparmor.allow_nesting = 1`: without them systemd cannot give a
   unit a mount namespace, and `mariadb.service`, which has
   `ProtectSystem=full` and `ProtectHome=true`, fails with
   `status=226/NAMESPACE` before its own first line runs.
6. Waits for a global IPv6 address (`lxc-info -i`), then for the first boot
   to finish: `RUN_FIRSTBOOT=false` in the rootfs copy of
   `/etc/default/inithooks`, and then confconsole or an SSH banner.
7. **Connects to the database.** `mysql --user=admin --host=::1
   --protocol=TCP --execute='SELECT 1'` inside the container, with the
   declared password in `MYSQL_PWD`. The password comes from the secret
   file the test wrote in step 3 and from nowhere else, so a row back is
   the proof that the declarative path carried it end to end. A listening
   port would prove nothing: the database listens whatever password it
   ended up with.
8. Checks `webmin-mysql` is installed and that Webmin answers over IPv6 on
   12321.
9. Runs `keel diff --root <rootfs> --spec tests/instance.yaml`; exit 0 or
   13 (no drift) passes.

## Two nodes, and the replication phase

`--roles "primary replica"` boots one container per role on the same bridge
and runs everything above on each of them, then proves replication between
them. The reusable workflow passes it, because `.github/workflows/tests.yml`
declares `roles: primary replica`; by hand it is

    tests/boot-test.sh mariadb --roles "primary replica" \
        --nodes-lib /path/to/.github/lib/boot-test-nodes.sh \
        --layers-dir https://mirror.keellinux.org/layers --bridge lxcbr0

where the node library is `lib/boot-test-nodes.sh` of `keel-linux/.github`,
which the workflow clones for itself. The count is the number of role names,
so Galera's three later is another name and nothing here assumes two.

Containers are `NAME-1` and `NAME-2`. Each is told which one it is in
`/etc/keel/node.env` in its own rootfs, and once both have an address each
gets `/etc/keel/peers.env` with every node's literal IPv6 address. The test
addresses the other node by that literal address and never by a name, because
on Debian a name resolves to IPv4 alone.

### What the phase does, and who owns each piece later

The phase exists because handbook decision 0013 says the console's
replication modes should not be built if they cannot be tested in the gate.
It is therefore deliberately hand configuration, and every piece of it is
something the appliance will own:

| Done by hand here | Owner once the console has the modes |
| --- | --- |
| `/etc/keel/node.env`, the role | the instance description (decision 0013, phase 2) |
| the drop-in `zz-keel-boot-test-replication.cnf`: `server_id`, `bind-address` with this node's own literal global address, `skip_name_resolve`, and `log_bin` on the primary alone | the Primary and Replica screens |
| the replication account, authorised for the peer's /64 rather than one address | the Primary screen, which is what "a primary holds authorizations" means |
| a host row for the administrative account on the replica | nobody: it exists only so the row can be read from the other machine by a declared account |
| `CHANGE MASTER TO ... MASTER_USE_GTID=slave_pos` and `START SLAVE` | the Replica screen |
| an empty `gtid_slave_pos`, meaning "from the start of the primary's log" | the Replica screen's seeding step, which will be a backup of the primary |

In order: the drop-in and a restart on both; each node's database confirmed
reachable from the other over IPv6; the accounts; `START SLAVE`; the server
asked what it thinks it is (`Slave_running`, not the configuration read
back); then a value generated on the host for this run, written on the
primary and read from the replica **from the primary container** over IPv6.
The same value appearing there can only mean replication carried it.

`keel diff` runs before the phase on purpose: the drop-in is drift the
description says nothing about, which is the class of problem decision 0013
lists under promotion.

`secrets.app_password` in `tests/instance.yaml` is the replication
credential. It is declared rather than invented in the test because the point
is that a replication password arrives the way the administrative one does.
No hook on this layer reads `APP_PASS`, and `keel diff` never compares secret
values, so a single node run is unaffected.

<!-- Cancellation check of the two node teardown, 2026-09-27. This branch is
     deleted once the check is recorded. -->
