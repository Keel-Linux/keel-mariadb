# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/mariadb.sh | tests/mariadb.bats (13 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/35mysqlpass | tests/hook.bats (12 tests) | 95.45 percent (21/22) under kcov | the uncovered line is `done < <(bin/dbpass.py ...)`, a process substitution kcov attributes to no line; the loop itself is covered |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (68 tests) | 100 percent (248/248) under kcov | argument parsing, address discovery, deadlines, the container marks, the database, module, Webmin and diff verdicts, the node options, and the replication phase's drop-in, accounts, statements and verdicts |
| bin/keel-archive-check | tests/archive-check.bats (25 tests) | 100 percent (52/52) under kcov | the build time check: the archive copy in the build tree is the live archive, the source entry names the keyring through signed-by, nothing says trusted=yes, and the signature on the copied InRelease verifies against the staging key (tracker#7) |
| overlay/usr/lib/inithooks/bin/dbpass.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | the build | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the four measured shell files: **99.73 percent (364/365)**,
118 bats tests. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which
the workflow sets to 95, the lowest measured file. It is only ever raised
(decision 0006).

    $ COVERAGE_THRESHOLD=95 tests/coverage.sh
    kcov line coverage (threshold 95 percent):
     100.00  43/43  mariadb.sh
      95.45  21/22  35mysqlpass
     100.00  248/248  boot-test-lib.sh
     100.00  52/52  keel-archive-check

The topology of a run with several nodes is not measured here because it is
not here: `lib/boot-test-nodes.sh` of `keel-linux/.github` holds it, at 113
of 113 lines and 39 bats tests in that repository, which is where the shell
the reusable workflows lend out is tested.

## What the hook tests cover

The hook is executed for real against scratch directories, with PATH stubs
for `systemctl`, `mysqladmin` and `mysql`, and stubs of
`bin/mysqlconf.py` and `bin/dbpass.py` under a scratch `INITHOOKS_PATH`
whose `lib` is a symlink to the real library, so kcov measures the file
the layer ships. No test needs root, a database or a network.

What they are really about is the defect these two layers exposed: the
declared password is what reaches the database, it reaches every host of
the administrative account, the hook proves it by connecting and fails
when the database refuses it, a `MYSQL_PASS` in the conf is not a password
and is ignored, a headless boot with nothing declared fails with the name
of the field to declare, the dialog is used only when there is a terminal,
`APP_DB_USER` renames the account and a name that would need quoting is
refused before anything runs, and the service is started and waited for
before any password is set.

## The appliance gate

`appliance / build-and-boot` runs through the organization's
`test-appliance.yml` on the self-hosted `keel-lxc` runner, which fetches
the published layer from `https://mirror.keellinux.org/layers`, verifies
it, assembles it, boots **two** containers of it on one bridge and runs
`tests/boot-test.sh` against them. Nothing is built there.

### Two nodes, and replication proved (2026-09-27)

The caller declares `roles: primary replica`, and the gate boots one
container per role from the same published layer. Run 36313809854 of this
repository, **1m17s for the job**, 54s of it in the boot test:

| | |
| --- | --- |
| layer | `mariadb`, sha256 `0adca434`, parent `core` `7acf2c53`, `keel verify` exit 9 |
| assemble | 16s and 14s, one rootfs per node, one layer cache for the run |
| addresses | both from `lxcbr0` 6s after start, `fc42:5009:ba4b:5ab0:2eeb:3007:b430:dac0` and `...:a565:28bb:b076:701` |
| first boot | finished on both 16s after start |
| per node | declared password authenticated on `[::1]:3306`, `webmin-mysql` installed, Webmin 200 on 12321, `keel diff` 6 same and 0 drift |
| reachability | each node's 3306 answered from the other over IPv6 4s after the restarts |
| replication | `'repl'@'fc42:5009:ba4b:5ab0:%'`, `Slave_running ON` |
| the proof | a value generated for the run, written on the primary and read from the replica by `admin` from the primary container: the same value |
| teardown | both containers and the scratch tree gone, 0 container monitors left |

What the phase configures by hand, and who owns each piece once the console
has the modes of decision 0013, is the table in `tests/README.md`. None of
it ships in the layer.

### What the gate found once the layer booted (2026-09-27)

The `mariadb` layer was published (65,443,671 bytes, parent `core`
7acf2c53) and the job ran for real. It failed, and the cause was in the
test, not the layer:

    ERR: [35mysqlpass] failed - exit code 1
    boot-test: the database refused the declared password
    ERR: [15regen-sslcert] failed - exit code 1
    ERR: [95secupdates] failed - exit code 1

Reproduced on the build host from the published chain.
`systemctl show mariadb.service -p ExecStartPre` reported
`code=exited status=226`: under the stock LXC container apparmor profile
systemd cannot give a unit a mount namespace, and `mariadb.service` has
`ProtectSystem=full` and `ProtectHome=true`, so it failed before its own
first line ran. `systemd-journald`, `systemd-logind`, `systemd-sysusers`,
`systemd-sysctl` and `tmp.mount` failed the same way in the same
container, which is why `15regen-sslcert` and `95secupdates` failed
beside it and why the container had no journal to read.

`bt_lxc_config` now writes `lxc.apparmor.profile = generated` and
`lxc.apparmor.allow_nesting = 1`, and `bt_mark_container` does what
buildtasks' container patch does, both ported from keel-nodebb, which met
the second one as a first boot that never returned. Measured on the build
host against the published chain with both in place: every hook from
`01ipconfig` to `98finalize` completes, the only failed unit is
`inithooks-restart-getty1.service`, which needs a tty no container has,
and

    $ mysql --user=admin --host=::1 --protocol=TCP --execute='SELECT 1, CURRENT_USER()'
    1	admin@localhost

with the declared password in `MYSQL_PWD`, while the wrong password gives
`ERROR 1045 (28000): Access denied for user 'admin'@'localhost' (using
password: YES)`.

State on 2026-09-27: green once this lands. It becomes a required status
on `main` then.

## Plan

- Publish the layer, then require `appliance / build-and-boot` on `main`.
- Measure `conf.d/main`. A build time script that runs inside a chroot as
  root is the case decision 0003 splits: the decisions it makes (which
  account, which hosts, which hash) are already in `lib/mariadb.sh` and
  measured, and what is left is the SQL and the apt calls.
- Move `bin/dbpass.py` to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
