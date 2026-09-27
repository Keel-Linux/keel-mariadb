#!/usr/bin/env bats
# bin/keel-archive-check: the copy of the project archive inside a build tree
# has to be the archive as it is right now, and the build's apt has to be able
# to verify it. Everything here runs against scratch directories and a key
# generated for the test; no root, no network, no fab.

setup_file() {
    # One key for the whole file: generating an ed25519 key is a second, and
    # every test needs the same signature to verify against.
    export GNUPGHOME="$BATS_FILE_TMPDIR/gnupg"
    mkdir -m 700 -p "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-generate-key \
        'Keel Test Staging <staging@example.invalid>' ed25519 sign never
    gpg --batch --quiet --passphrase '' --quick-generate-key \
        'Keel Test Other <other@example.invalid>' ed25519 sign never

    export GOOD_KEY OTHER_KEY
    GOOD_KEY=$(key_fingerprint staging@example.invalid)
    OTHER_KEY=$(key_fingerprint other@example.invalid)

    export GOOD_KEYRING="$BATS_FILE_TMPDIR/good.asc"
    export OTHER_KEYRING="$BATS_FILE_TMPDIR/other.asc"
    gpg --batch --quiet --armor --export "$GOOD_KEY" > "$GOOD_KEYRING"
    gpg --batch --quiet --armor --export "$OTHER_KEY" > "$OTHER_KEYRING"

    export SIGNED_INRELEASE="$BATS_FILE_TMPDIR/InRelease"
    printf 'Suite: staging\nCodename: trixie-staging\n' \
        | gpg --batch --quiet --local-user "$GOOD_KEY" --clearsign \
        > "$SIGNED_INRELEASE"
}

key_fingerprint() {
    gpg --batch --with-colons --list-keys "$1" \
        | awk -F: '$1 == "fpr" { print $10; exit }'
}

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    CHECK="$ROOT/bin/keel-archive-check"
    scratch="$BATS_TEST_TMPDIR/archive"
    DIST=trixie-staging
    ARCH=amd64
    INDEX="dists/$DIST/main/binary-$ARCH/Packages"
    KEYRING_PATH=/etc/apt/keyrings/keel-staging-keyring.asc
    LIST_PATH=/etc/apt/sources.list.d/keel-staging.list

    SOURCE="$scratch/srv/keel-apt/repo"
    TREE="$scratch/build/root.patched"
    COPY="$TREE/srv/keel-apt/repo"
    mkdir -p "$SOURCE/$(dirname "$INDEX")" "$COPY/$(dirname "$INDEX")" \
        "$COPY/dists/$DIST" "$TREE/etc/apt/keyrings" "$TREE/etc/apt/sources.list.d"

    write_index "$SOURCE/$INDEX" 2.3.6+keel4
    write_index "$COPY/$INDEX" 2.3.6+keel4
    cp "$SIGNED_INRELEASE" "$COPY/dists/$DIST/InRelease"
    cp "$GOOD_KEYRING" "$TREE$KEYRING_PATH"
    write_list "$DIST" "$KEYRING_PATH"

    export KEEL_ARCHIVE_KEY="$GOOD_KEY"
}

write_index() {
    cat > "$1" <<INDEX
Package: inithooks
Version: $2
Architecture: all
INDEX
}

write_list() {
    echo "deb [signed-by=$2] file:///srv/keel-apt/repo $1 main" \
        > "$TREE$LIST_PATH"
}

check() {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" "$@"
}

@test "a copy that is the archive, signed by the named key, passes and says so" {
    check root.patched
    [ "$status" -eq 0 ]
    [[ "$output" == *"[archive-check root.patched]"* ]]
    [[ "$output" == *"is the archive at $SOURCE/$INDEX"* ]]
    [[ "$output" == *"verifies against $GOOD_KEY"* ]]
}

@test "the label defaults to the tree when it is not given" {
    check
    [ "$status" -eq 0 ]
    [[ "$output" == *"[archive-check $TREE]"* ]]
}

@test "a copy of an older archive fails and shows what changed" {
    write_index "$COPY/$INDEX" 2.3.6+keel1
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not $SOURCE/$INDEX"* ]]
    [[ "$output" == *"-Version: 2.3.6+keel1"* ]]
    [[ "$output" == *"+Version: 2.3.6+keel4"* ]]
    [[ "$output" == *"build/stamps/bootstrap"* ]]
}

@test "a build tree with no copy at all fails" {
    rm -f "$COPY/$INDEX"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"the build tree has no archive index"* ]]
}

@test "an archive with no index for this distribution fails" {
    run "$CHECK" "$SOURCE" "$TREE" trixie-nowhere "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"the archive has no index"* ]]
}

@test "too few arguments is a usage error" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
    [[ "$output" == *"KEEL_ARCHIVE_KEY (required)"* ]]
}

@test "too many arguments is a usage error" {
    run "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" label extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
}

@test "an empty argument is a usage error rather than a wrong path" {
    run "$CHECK" "$SOURCE" "$TREE" "" "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: keel-archive-check"* ]]
}

@test "no key named is a failure, because a keyring alone promises nothing" {
    KEEL_ARCHIVE_KEY="" check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"KEEL_ARCHIVE_KEY names no key"* ]]
}

@test "trusted=yes in the entry itself fails: that is the defect" {
    echo "deb [trusted=yes] file:///srv/keel-apt/repo $DIST main" > "$TREE$LIST_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"verification is switched off for /srv/keel-apt/repo"* ]]
    [[ "$output" == *"keel-staging.list"* ]]
}

@test "trusted=yes on this archive in another file fails too" {
    printf 'deb [ trusted = yes ] file:///srv/keel-apt/repo trixie-staging main\n' \
        > "$TREE/etc/apt/sources.list.d/other.list"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"verification is switched off for /srv/keel-apt/repo"* ]]
    [[ "$output" == *"other.list"* ]]
}

@test "Trusted: yes on this archive in a deb822 source fails as well" {
    printf 'Types: deb\nURIs: file:///srv/keel-apt/repo\nSuites: trixie-staging\nTrusted: yes\n' \
        > "$TREE/etc/apt/sources.list.d/other.sources"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"verification is switched off for"* ]]
}

@test "the captured pool may say Trusted: yes, because it is not this archive" {
    # Decision 0012: a file: index generated on this machine, whose digests
    # keel-pool verify checks. Refusing it would fail every pinned build.
    printf 'Types: deb\nURIs: file:/keel-pool\nSuites: 2026-09-27\nTrusted: yes\n' \
        > "$TREE/etc/apt/sources.list.d/keel-pool.sources"
    check bootstrap
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing is trusted unverified"* ]]
}

@test "the archive a trusted=yes is refused for is overridable" {
    printf 'deb [trusted=yes] file:///elsewhere/repo trixie main\n' \
        > "$TREE/etc/apt/sources.list.d/other.list"
    run env KEEL_ARCHIVE_KEY="$GOOD_KEY" KEEL_ARCHIVE_PATH=/elsewhere/repo \
        "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"switched off for /elsewhere/repo"* ]]
}

@test "a tree with no source entry at all fails" {
    rm -f "$TREE$LIST_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no source entry at"* ]]
}

@test "a source file with no deb line fails" {
    printf '# nothing but a comment\n' > "$TREE$LIST_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no deb line"* ]]
}

@test "an entry that does not name the keyring fails" {
    echo "deb file:///srv/keel-apt/repo $DIST main" > "$TREE$LIST_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not name signed-by=$KEYRING_PATH"* ]]
}

@test "an entry that names another keyring fails" {
    write_list "$DIST" /usr/share/keyrings/somebody-else.asc
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not name signed-by=$KEYRING_PATH"* ]]
}

@test "an entry for another distribution fails" {
    write_list trixie "$KEYRING_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not name the distribution $DIST"* ]]
}

@test "a missing keyring fails" {
    rm -f "$TREE$KEYRING_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or empty: the build cannot verify"* ]]
}

@test "an empty keyring fails" {
    : > "$TREE$KEYRING_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or empty: the build cannot verify"* ]]
}

@test "a keyring holding another key fails, present though it is" {
    cp "$OTHER_KEYRING" "$TREE$KEYRING_PATH"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not hold key $GOOD_KEY"* ]]
}

@test "a keyring that is not a public key file fails" {
    printf 'this is not a key\n' > "$TREE$KEYRING_PATH"
    KEEL_ARCHIVE_KEY="$GOOD_KEY" check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not hold key $GOOD_KEY"* ]]
}

@test "an unsigned copy of the archive fails" {
    rm -f "$COPY/dists/$DIST/InRelease"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or empty: this copy of the archive is not signed"* ]]
}

@test "a signature made by another key fails" {
    printf 'Suite: staging\n' \
        | gpg --batch --quiet --local-user "$OTHER_KEY" --clearsign \
        > "$COPY/dists/$DIST/InRelease"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not verify against"* ]]
}

@test "a signature over content that was changed afterwards fails" {
    sed -i 's/^Suite: staging$/Suite: tampered/' "$COPY/dists/$DIST/InRelease"
    check bootstrap
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not verify against"* ]]
}

@test "the keyring path and the source path are overridable together" {
    mkdir -p "$TREE/usr/share/keyrings"
    mv "$TREE$KEYRING_PATH" "$TREE/usr/share/keyrings/elsewhere.asc"
    echo "deb [signed-by=/usr/share/keyrings/elsewhere.asc] file:///srv/keel-apt/repo $DIST main" \
        > "$TREE/etc/apt/sources.list.d/elsewhere.list"
    rm -f "$TREE$LIST_PATH"
    run env KEEL_ARCHIVE_KEY="$GOOD_KEY" \
        KEEL_ARCHIVE_KEYRING=/usr/share/keyrings/elsewhere.asc \
        KEEL_ARCHIVE_LIST=/etc/apt/sources.list.d/elsewhere.list \
        "$CHECK" "$SOURCE" "$TREE" "$DIST" "$ARCH" bootstrap
    [ "$status" -eq 0 ]
    [[ "$output" == *"verifies against $GOOD_KEY"* ]]
}
