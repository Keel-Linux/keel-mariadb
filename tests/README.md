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
  container, do to the tree what `pct create` of Proxmox VE does (no
  machine id, its preset, so the first start is the first boot of
  systemd), install the description, the secrets and the conf, start the
  container, wait, connect to the database, check that 3306 is not on the
  uplink (no wildcard listener, no answer from the host; #29), check
  Webmin, `keel diff`. It builds nothing, so it needs no fab, deck or
  buildtasks. The workflow installs the keel-mariadb package built from
  the branch before the first boot (`package_artifact`), so the job is in
  `packages.yml`, beside that build.
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
  with every system command stubbed, and inithooks' `lib/console.sh` a
  stand-in that answers from `INITHOOKS_UNATTENDED`, as `run` exports it.
- `socket-wildcard.bats`: `bin/keel-socket-wildcard`, the build check of
  `conf.d/main`, against scratch trees: a socket unit that can listen on a
  wildcard address for 3306 and is not masked fails the build (#29).
- `package.bats`: builds `packages/keel-mariadb` with `dpkg-buildpackage`
  and reads back its fields, its files, the manifest and the preset, and
  runs its maintainer scripts with `deb-systemd-helper` stubbed. Needs `dpkg-dev`,
  `debhelper` and `python3-yaml` besides `bats`; it runs in the check
  `packages / build` (`.github/workflows/packages.yml`), with lintian over
  the source and binary package, and not under `coverage.sh`.
- `coverage.sh`: runs every bats suite but `package.bats` under kcov and
  fails when any measured file is below `COVERAGE_THRESHOLD` (default 95).
- `instance.yaml`: the description the test container boots from. It
  declares `secrets.db_password` from a file, which is the point of the
  test.

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/mariadb.bats
    bats tests/hook.bats
    bats tests/boot-test.bats
    bats tests/dbpass.bats
    bats tests/socket-wildcard.bats
    COVERAGE_THRESHOLD=95 tests/coverage.sh

`COVERAGE_DIR=coverage tests/coverage.sh` keeps the kcov reports.

## The package on a built image

What the manifest does on a machine is proven on an image built from this
branch, since the boot test boots the published layer: `conf.d/main` runs
`keel manifest validate mariadb` on the built tree, and on the booted
container `keel manifest show mariadb --resolved` lists Core's five
overlays and the server, `keel inspect` writes `appliance.name: mariadb`,
and a description with `appliance.name: mariadb`, `installation.mode`, the
five overlays written out and `app.options.db_user` passes `keel spec
validate`. `tests/instance.yaml` does not name the appliance yet: the gate
boots the published layer, and 19.0-5 has no manifest to hold the name
against. It gains the section once a layer with the package is published.

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

`--keel-deb FILE` installs a locally built keel into every node once it has
booted. The gate never passes it: there the keel under test is the one the
published layer carries, which is the point of assembling a published layer.
It is for the maintainer proving a keel before the layer that carries it is
published, which is the order the replication feature had to be done in.

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

### keel configures it, and the test asserts the outcome

This phase used to configure the two machines by hand, and that table has
been emptied by keel-mariadb#9: what was hand configuration is now what
`keel spec apply --system-only` does from `database.server`, which is what
the console's Primary and Replica screens call.

| Was done by hand | Owner now |
| --- | --- |
| `/etc/keel/node.env`, the role | still the test's, and still how a node learns which one it is; it decides which section is written into that node's description |
| the drop-in: `server_id`, `bind-address`, `skip_name_resolve`, `log_bin` on the primary | `keel spec apply --system-only`, from `listen` and `role`. The test reads the file back and never writes it |
| the replication account, authorised for the peer's /64 | `keel`, from `replication.allowed_from`. The description carries the `/64`, and keel writes the host pattern MariaDB holds |
| `CHANGE MASTER TO ... MASTER_USE_GTID=slave_pos` and `START SLAVE` | `keel`, from `replication.primary` |
| an empty `gtid_slave_pos` | `keel`, and only over a database that holds nothing, which is why the refusal below is asserted first |
| a host row for the administrative account on the replica | still the test's, and not part of the feature: it exists only so the row can be read from the other machine by a declared account. `SELECT` on the one database and never `ALL PRIVILEGES`, which carries `Repl_slave_priv` and would make the replica read as a primary |

What the test writes is a **description**, appended to `tests/instance.yaml`
in each node's own rootfs once the addresses exist: its role, the addresses
it answers on, and either the prefix it authorises or the endpoint it
replicates from. Nothing in it configures the other machine.

In order, each step named in the log (`step 8b, ...`) and in the last line
of a failed run (`boot-test: FAILED (exit N) in step ...`):

1. (8a) each node's description gains its `database.server` section;
2. (8b) **the primary converges first**, and its drop-in is read back: a
   server id and a binary log. keel asks the primary whether it answers as
   the replication account before it looks at the replica's data, so a
   replica applied before this step is refused for the primary's silence
   and the refusal over data is never asked (run 37838543320, 2026-10-08,
   `the primary [...]:3306 did not answer as 'repl'`);
3. (8c) the primary's database confirmed reachable from the replica over
   IPv6, at a literal address;
4. (8d) **the refusal, on a real server.** The replica is given a database
   of its own, `operatordata`, and told to become a replica. keel must exit
   16, say what it refused, and leave replication stopped. Becoming a
   replica replaces the local database, and it is the one property of this
   feature that loses data if it is wrong, so the gate asserts it and not
   only the unit tests. A refusal for any other reason fails the step and
   is quoted. The database is then dropped;
5. (8e) the administrative host row on the replica;
6. (8f) the replica converges, and its drop-in is read back: a server id
   and no binary log, because it reads the primary's;
7. (8g) the replica's database confirmed reachable from the primary, now
   that its apply gave it its listening address;
8. (8h) the server is asked what it thinks it is (`Slave_running`, not the
   configuration read back), and the primary is asked what it granted;
9. (8i) **`keel diff` on both nodes, with no drift.** It runs here and no
   longer before the phase: the machines are now what their descriptions
   say, which is the whole claim. Before the apply they were not;
10. (8j) a value generated on the host for this run, written on the primary
    and read from the replica **from the primary container** over IPv6. The
    same value appearing there can only mean replication carried it.

`secrets.app_password` in `tests/instance.yaml` is the replication
credential, and `database.server.replication.secret` names its file. It is
declared rather than invented in the test because the point is that a
replication password arrives the way the administrative one does. No hook on
this layer reads `APP_PASS`, and `keel diff` never compares secret values, so
a single node run is unaffected.
