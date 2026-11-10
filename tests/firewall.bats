#!/usr/bin/env bats
# The ports that the Webmin firewall of the recipe opens on the uplink
# (WEBMIN_FW_TCP_INCOMING of the Makefile; common's conf/turnkey.d/
# webmin-fw opens each of them). keel makes its nftables table from the
# manifests and opens a port of "expose: mesh" only on the WireGuard
# interface (keel/manifest/firewall.py, decision 0041, item 6). 3306 is a
# mesh port in the manifest, so it is not in this list (#31). Keel Core
# has no web shell on 12320 (TurnKey removed shellinabox in 18.0), so
# 12320 is not in it either. The services screen of confconsole names
# only what the image has.

bats_require_minimum_version 1.5.0

MAKEFILE="$BATS_TEST_DIRNAME/../Makefile"
SERVICES="$BATS_TEST_DIRNAME/../overlay/etc/confconsole/services.txt"

# the ports of the one WEBMIN_FW_TCP_INCOMING line, one a line
incoming() {
    [ "$(grep -c '^WEBMIN_FW_TCP_INCOMING *=' "$MAKEFILE")" -eq 1 ]
    sed -n 's/^WEBMIN_FW_TCP_INCOMING *= *//p' "$MAKEFILE" | tr -s ' ' '\n'
}

@test "firewall: the uplink list opens SSH and Webmin" {
    run incoming
    [ "$status" -eq 0 ]
    grep -qx 22 <<< "$output"
    grep -qx 12321 <<< "$output"
}

@test "firewall: the uplink list does not open 3306, a mesh port (#31)" {
    run incoming
    [ "$status" -eq 0 ]
    run ! grep -qx 3306 <<< "$output"
}

@test "firewall: the uplink list does not open 12320, no web shell is there" {
    run incoming
    [ "$status" -eq 0 ]
    run ! grep -qx 12320 <<< "$output"
}

@test "services: no web shell, which the image does not have" {
    run ! grep -qi 'web shell' "$SERVICES"
    run ! grep -q ':12320' "$SERVICES"
}

@test "services: Webmin, SSH and MariaDB, for both address families" {
    [ "$(grep -c '^Webmin: ' "$SERVICES")" -eq 2 ]
    [ "$(grep -c '^SSH/SFTP: ' "$SERVICES")" -eq 2 ]
    [ "$(grep -c '^MariaDB: ' "$SERVICES")" -eq 2 ]
}
