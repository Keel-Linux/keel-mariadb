#!/usr/bin/env bats
# The keel-mariadb package of packages/keel-mariadb (handbook decision 0041;
# issue #25): built for real with dpkg-buildpackage, then its fields, its
# files and the manifest it ships read back. Needs dpkg-dev, debhelper and
# python3-yaml; no root, no network. It runs in the check "packages / build"
# (.github/workflows/packages.yml), not under tests/coverage.sh, which
# measures shell and whose hosted runner has no debhelper.

bats_require_minimum_version 1.5.0

PACKAGE_DIR="$BATS_TEST_DIRNAME/../packages/keel-mariadb"

setup_file() {
    BUILD=$(mktemp -d)
    export BUILD
    cp -a "$PACKAGE_DIR" "$BUILD/src"
    (cd "$BUILD/src" && dpkg-buildpackage -us -uc -b >"$BUILD/build.log" 2>&1)
    DEB=$(ls "$BUILD"/keel-mariadb_*_all.deb)
    export DEB
}

teardown_file() {
    rm -rf "$BUILD"
}

# the manifest as Python reads it, one expression per call
manifest() {
    python3 -c 'import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$PACKAGE_DIR/manifest.yaml" "$1"
}

# the package

@test "one binary package, keel-mariadb, architecture all" {
    run dpkg-deb -f "$DEB" Package Architecture
    [ "$status" -eq 0 ]
    [ "$output" = $'Package: keel-mariadb\nArchitecture: all' ]
}

# keel-core 0.1.3 is the first with the vip overlay a pair needs; keel
# 0.23.0 the first that configures the pair of docs/replication.md;
# mariadb-server ships the unit the manifest names (rule 5)
@test "it depends on the Core that carries the VIP, the keel of the pair, and the server" {
    run dpkg-deb -f "$DEB" Depends
    [ "$status" -eq 0 ]
    [ "$output" = "keel (>= 0.23.0), keel-core (>= 0.1.3), mariadb-server" ]
}

@test "the manifest is installed as /usr/share/keel/appliances/mariadb.yaml" {
    dpkg-deb -x "$DEB" "$BUILD/root"
    cmp "$PACKAGE_DIR/manifest.yaml" "$BUILD/root/usr/share/keel/appliances/mariadb.yaml"
}

@test "the manifest is a plain file of mode 0644, owned by root" {
    run bash -c "dpkg-deb -c '$DEB' | grep ' ./usr/share/keel/appliances/mariadb.yaml$'"
    [ "$status" -eq 0 ]
    [[ "$output" == "-rw-r--r-- root/root "* ]]
}

@test "it installs the manifest and its documentation, nothing more" {
    run bash -c "dpkg-deb -c '$DEB' | awk '{print \$6}' | grep -v '/\$' | sort"
    [ "$status" -eq 0 ]
    [ "$output" = $'./usr/share/doc/keel-mariadb/changelog.gz\n./usr/share/doc/keel-mariadb/copyright\n./usr/share/keel/appliances/mariadb.yaml' ]
}

# the manifest

@test "manifest: an appliance named mariadb, version 1, on core" {
    run manifest '(m["manifest_version"], m["kind"], m["name"], m["base"])'
    [ "$status" -eq 0 ]
    [ "$output" = "(1, 'appliance', 'mariadb', 'core')" ]
}

# rule 16: an overlay once in the chain, so Core's five are inherited and
# never written here; the spec writes all five out (0027)
@test "manifest: no overlay of its own, Core's five are inherited" {
    run manifest '"overlays" in m'
    [ "$output" = "False" ]
}

@test "manifest: the server is its one process, mariadb.service on 3306 as a mesh port" {
    run manifest '[(p["name"], p["unit"], p["listen"]) for p in m["processes"]]'
    [ "$output" = "[('mariadb', 'mariadb.service', [{'port': 3306, 'protocol': 'tcp', 'expose': 'mesh'}])]" ]
}

# never public: the layer listens on loopback, a pair on the overlay
@test "manifest: nothing of this appliance is exposed on the uplink" {
    run manifest '[l["expose"] for p in m["processes"] for l in p["listen"] if l["expose"] == "public"]'
    [ "$output" = "[]" ]
}

@test "manifest: one check, Monit's mysql protocol on the loopback, restarting" {
    run manifest '[(c["name"], c["process"], c["type"], c["protocol"], c["address"], c["port"], c["on_failure"]) for c in m["checks"]]'
    [ "$output" = "[('mariadb', 'mariadb', 'protocol', 'mysql', 'loopback', 3306, 'restart')]" ]
}

# the name 35mysqlpass reads as DB_PASS; shared, since the mysql database
# replicates with the rest and a pair holds one value (rule 20: generated)
@test "manifest: db_password is its one secret, may be generated, and is shared by a pair" {
    run manifest '[(s["name"], s["generate"], s["shared"]) for s in m["secrets"]]'
    [ "$output" = "[('db_password', 'allowed', True)]" ]
}

# app.options.db_user renders to APP_DB_USER, which the hook reads (rule 27
# makes an undeclared option an error once the spec names the appliance)
@test "manifest: db_user is its one option, a string defaulting to admin" {
    run manifest '[(o["name"], o["type"], o["default"]) for o in m["options"]]'
    [ "$output" = "[('db_user', 'string', 'admin')]" ]
}

@test "manifest: the option's pattern is the account name rule of lib/mariadb.sh" {
    run manifest 'm["options"][0]["pattern"]'
    [ "$output" = '^[A-Za-z_][A-Za-z0-9_-]*$' ]
    run grep -F "MARIADB_USER_RE='^[A-Za-z_][A-Za-z0-9_-]*\$'" \
        "$BATS_TEST_DIRNAME/../overlay/usr/lib/inithooks/lib/mariadb.sh"
    [ "$status" -eq 0 ]
}
