# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/mariadb.sh | tests/mariadb.bats (13 tests) | 100 percent (43/43) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/35mysqlpass | tests/hook.bats (12 tests) | 95.45 percent (21/22) under kcov | the uncovered line is `done < <(bin/dbpass.py ...)`, a process substitution kcov attributes to no line; the loop itself is covered |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (36 tests) | 100 percent (140/140) under kcov | argument parsing, address discovery, deadlines, the database, module, Webmin and diff verdicts |
| overlay/usr/lib/inithooks/bin/dbpass.py | none | 0 | dialog wrapper, only reached with a terminal attached |
| conf.d/main | the build | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the three measured shell files: **99.51 percent (204/205)**,
61 bats tests. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which
the workflow sets to 95, the lowest measured file. It is only ever raised
(decision 0006).

    $ COVERAGE_THRESHOLD=95 tests/coverage.sh
    kcov line coverage (threshold 95 percent):
     100.00  43/43  mariadb.sh
      95.45  21/22  35mysqlpass
     100.00  140/140  boot-test-lib.sh

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

State on 2026-09-27: **the layer is not published yet, so the job skips
with a notice and passes.** It becomes a required status on `main` the
day the first `mariadb` layer reaches the mirror.

## Plan

- Publish the layer, then require `appliance / build-and-boot` on `main`.
- Measure `conf.d/main`. A build time script that runs inside a chroot as
  root is the case decision 0003 splits: the decisions it makes (which
  account, which hosts, which hash) are already in `lib/mariadb.sh` and
  measured, and what is left is the SQL and the apt calls.
- Move `bin/dbpass.py` to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
