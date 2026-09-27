# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/mariadb.sh | tests/mariadb.bats (13 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/35mysqlpass | tests/hook.bats (12 tests) | 95.45 percent (21/22) under kcov | the uncovered line is `done < <(bin/dbpass.py ...)`, a process substitution kcov attributes to no line; the loop itself is covered |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (43 tests) | 100 percent (153/153) under kcov | argument parsing, address discovery, deadlines, the container marks, the database, module, Webmin and diff verdicts |
| overlay/usr/lib/inithooks/bin/dbpass.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | the build | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the three measured shell files: **99.54 percent (217/218)**,
68 bats tests. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which
the workflow sets to 95, the lowest measured file. It is only ever raised
(decision 0006).

    $ COVERAGE_THRESHOLD=95 tests/coverage.sh
    kcov line coverage (threshold 95 percent):
     100.00  43/43  mariadb.sh
      95.45  21/22  35mysqlpass
     100.00  153/153  boot-test-lib.sh

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
it, assembles it, boots it in LXC and runs `tests/boot-test.sh`. Nothing
is built there.

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
