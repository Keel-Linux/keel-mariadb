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
  call, the database, module and Webmin verdicts, the diff verdict), as
  functions with no side effects, per decision 0004. Same shape as the one
  in keel-core and keel-nodebb.
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
2. Creates `var/lib/turnkey-info/inithooks.service/lxc` in the rootfs, the
   marker `bt-container` writes and the one `keel inspect` reads to call
   the machine a container (`network.managed_by: host`).
3. Writes a random `root_password` and `db_password` under
   `etc/keel/secrets` (mode 0600) and installs `tests/instance.yaml` at
   `etc/keel/instance.yaml` and `etc/inithooks.yaml`.
4. Renders the description into the rootfs `etc/inithooks.conf` with
   `keel spec apply`, from a copy whose secret references point inside the
   rootfs. Without the conf the first boot is not headless: `30rootpass`
   and `35mysqlpass` would have nothing declared and no terminal.
5. Writes an LXC config for that rootfs on the bridge and starts the
   container.
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
