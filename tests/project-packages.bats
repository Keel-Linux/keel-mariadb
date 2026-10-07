#!/usr/bin/env bats
# bin/keel-project-packages, with dpkg-query and apt-cache replaced by stubs
# that answer what apt 3 prints on trixie. The policy fixtures are the shape
# measured on the build host on 2026-10-07.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECK="$REPO/bin/keel-project-packages"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    export DPKG_QUERY="$STUBS/dpkg-query" APT_CACHE="$STUBS/apt-cache"
    export KEEL_APT_TRACK=testing
    installed inithooks 2.3.6+keel23
    installed confconsole 2.2.3+keel15
    installed keel 0.19.0
    policy inithooks 2.3.6+keel23 2.3.6+keel23 trixie-testing 2.3.6+keel5 trixie
    policy confconsole 2.2.3+keel15 2.2.3+keel15 trixie-testing 2.2.3+keel2 trixie
    policy keel 0.19.0 0.19.0 trixie-testing 0.3.5 trixie
    write_stubs
}

# installed PACKAGE VERSION: what dpkg-query reports for it
installed() {
    printf 'install ok installed %s\n' "$2" > "$STUBS/$1.status"
}

# policy PACKAGE INSTALLED CANDIDATE SUITE OLD OLDSUITE: apt-cache policy
# output, the candidate in SUITE and an older version in OLDSUITE
policy() {
    cat > "$STUBS/$1.policy" <<EOF
$1:
  Installed: $2
  Candidate: $3
  Version table:
 *** $3 990
        990 https://archive.keellinux.org $4/main amd64 Packages
        100 /var/lib/dpkg/status
     $5 990
        990 https://archive.keellinux.org $6/main amd64 Packages
EOF
}

write_stubs() {
    printf '#!/bin/bash\nf="%s/${!#}.status"\n[ -f "$f" ] || exit 1\ncat "$f"\n' "$STUBS" > "$DPKG_QUERY"
    printf '#!/bin/bash\ncat "%s/$2.policy"\n' "$STUBS" > "$APT_CACHE"
    chmod +x "$DPKG_QUERY" "$APT_CACHE"
}

@test "the three project packages pass when each is the testing candidate from the Keel archive" {
    run "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inithooks 2.3.6+keel23 from archive.keellinux.org trixie-testing"* ]]
    [[ "$output" == *"confconsole 2.2.3+keel15 from archive.keellinux.org trixie-testing"* ]]
    [[ "$output" == *"keel 0.19.0 from archive.keellinux.org trixie-testing"* ]]
}

@test "a package left below its candidate fails, which is what a stale or downgrading source leaves" {
    installed inithooks 2.3.6+keel5
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"inithooks is 2.3.6+keel5, the archive offers 2.3.6+keel23"* ]]
}

@test "a candidate from another source than the Keel archive's suite fails" {
    cat > "$STUBS/keel.policy" <<'EOF'
keel:
  Installed: 0.19.0
  Candidate: 0.19.0
  Version table:
 *** 0.19.0 1001
       1001 file:/srv/keel-apt/repo trixie-staging/main amd64 Packages
        100 /var/lib/dpkg/status
EOF
    run "$CHECK" keel
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel 0.19.0 is not from https://archive.keellinux.org trixie-testing"* ]]
}

@test "the stable track wants trixie, so a testing-only candidate fails there" {
    run env KEEL_APT_TRACK=stable "$CHECK" keel
    [ "$status" -eq 1 ]
    [[ "$output" == *"not from https://archive.keellinux.org trixie"* ]]
    policy keel 0.19.0 0.19.0 trixie 0.3.5 trixie-testing
    run env KEEL_APT_TRACK=stable "$CHECK" keel
    [ "$status" -eq 0 ]
    unset KEEL_APT_TRACK
    run "$CHECK" keel
    [ "$status" -eq 0 ]
}

@test "a package that is not installed fails, and the others are still checked" {
    rm "$STUBS/confconsole.status"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confconsole is not installed"* ]]
    [[ "$output" == *"keel 0.19.0 from archive.keellinux.org trixie-testing"* ]]
}

@test "an unknown track stops the check" {
    run env KEEL_APT_TRACK=nightly "$CHECK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be 'stable' or 'testing', got 'nightly'"* ]]
}
