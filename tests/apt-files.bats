#!/usr/bin/env bats
# The apt files this recipe leaves in the image (Keel-Linux/common#30,
# tracker#23). Common ships the appliance's Keel source and its pin at 990
# (overlays/turnkey.d/keel-apt); a recipe overlay at the same paths would win
# over them, so this recipe ships neither. The build time archive still has
# to win over TurnKey's 999 pin while the recipe upgrades the project
# packages, so conf.d/main pins it by its Label for the build only.
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

@test "the build time pin names the staging Label, and is written before the upgrade" {
    local pin upgrade
    pin="$(line "printf 'Package: *\nPin: release l=Keel Linux staging\nPin-Priority: 1001\n' \\")"
    # the backslash is the script's line continuation, matched literally
    # shellcheck disable=SC1003
    upgrade="$(line 'apt-get install -y --only-upgrade \')"
    [ -n "$pin" ]
    [ -n "$upgrade" ]
    [ "$pin" -lt "$upgrade" ]
    grep -qxF '    > /etc/apt/preferences.d/keel-staging' "$MAIN"
}

@test "the build time pin goes with the build time source" {
    local list pin
    list="$(line 'rm -f /etc/apt/sources.list.d/keel-staging.list')"
    pin="$(line 'rm -f /etc/apt/preferences.d/keel-staging')"
    [ -n "$list" ]
    [ -n "$pin" ]
    [ "$pin" -eq $((list + 1)) ]
}

@test "the build fails when an apt file still names the build time archive" {
    grep -qF "grep -rlsE 'trixie-staging|/srv/keel-apt|l=Keel Linux staging'" "$MAIN"
    run ! grep -q "Enabled: no' /etc/apt/sources.list.d/keel.sources" "$MAIN"
}

@test "conf.d/main parses" {
    bash -n "$MAIN"
}
