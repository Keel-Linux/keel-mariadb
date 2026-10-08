#!/usr/bin/env bats
# The apt files of this recipe (Keel-Linux/common#30 and #32, tracker#23).
# Common ships the appliance's Keel source and its pin at 990
# (overlays/turnkey.d/keel-apt); a recipe overlay at the same paths would win
# over them, so this recipe ships neither. The project packages come from the
# Keel archive like every other Keel package: there is no build time archive,
# no staging source and no staging pin anywhere in the recipe.
#
# conf.d/main runs inside a chroot during the build; what it leaves is proved
# on the booted machine by the boot test. These check the recipe itself.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MAIN="$REPO/conf.d/main"
}

# line LITERAL: the line number of the first line of conf.d/main equal to it
line() {
    grep -nxF -- "$1" "$MAIN" | head -n 1 | cut -d: -f1
}

@test "the overlay ships no Keel source and no Keel pin" {
    [ ! -e "$REPO/overlay/etc/apt/sources.list.d/keel.sources" ]
    [ ! -e "$REPO/overlay/etc/apt/preferences.d/keel" ]
    run ! grep -rlsE 'Pin-Priority: *1001' "$REPO/overlay"
}

@test "no staging source, pin, keyring or archive copy is named anywhere in the build" {
    # the one line allowed to name them is conf.d/main's guard, which fails
    # the build when an apt file still does
    run bash -c "grep -rnE 'trixie-staging|Keel Linux staging|keel-staging|/srv/keel-apt|KEEL_APT_(REPO|DIST|KEY)' \
        '$REPO/Makefile' '$REPO/plan' '$REPO/conf.d' '$REPO/overlay' | grep -vF \"if grep -rlsE 'trixie-staging|/srv/keel-apt|l=Keel Linux staging|keel-staging'\""
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run ! grep -nE 'Pin-Priority: *1001' "$MAIN"
    [ ! -e "$REPO/bin/keel-archive-check" ]
}

@test "the project packages are upgraded from the archive, then proved to be its candidates" {
    local update upgrade check
    update="$(line 'apt-get update --error-on=any')"
    # the backslash is the script's line continuation, matched literally
    # shellcheck disable=SC1003
    upgrade="$(line 'apt-get install -y --only-upgrade \')"
    check="$(line '/usr/local/lib/keel-build/keel-project-packages inithooks confconsole keel keel-mariadb')"
    [ -n "$update" ] && [ -n "$upgrade" ] && [ -n "$check" ]
    [ "$update" -lt "$upgrade" ]
    [ "$upgrade" -lt "$check" ]
    grep -qxF '    inithooks confconsole keel' "$MAIN"
}

@test "the check is copied into the tree before the conf scripts and leaves it before the image is packed" {
    grep -qF 'install -D -m 755 $(CURDIR)/bin/keel-project-packages $O/root.patched$(KEEL_BUILD_TOOLS)/keel-project-packages;' "$REPO/Makefile"
    grep -qxF 'root.patched/pre += $(_keel_root.patched/pre)' "$REPO/Makefile"
    local check remove lists
    check="$(line '/usr/local/lib/keel-build/keel-project-packages inithooks confconsole keel keel-mariadb')"
    remove="$(line 'rm -rf /usr/local/lib/keel-build')"
    lists="$(line 'rm -rf /var/lib/apt/lists/*')"
    [ -n "$remove" ] && [ -n "$lists" ]
    [ "$check" -lt "$remove" ]
    [ "$check" -lt "$lists" ]
    grep -qxF '[ ! -e /usr/local/lib/keel-build ]' "$MAIN"
}

@test "the build fails when an apt file still names the staging archive" {
    grep -qF "grep -rlsE 'trixie-staging|/srv/keel-apt|l=Keel Linux staging|keel-staging'" "$MAIN"
    run ! grep -q "Enabled: no' /etc/apt/sources.list.d/keel.sources" "$MAIN"
}

@test "conf.d/main parses" {
    bash -n "$MAIN"
}
