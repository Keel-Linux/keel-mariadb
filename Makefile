# keel-mariadb: MariaDB, the Webmin module for it, and nothing else.
# Compatible with TurnKey Linux appliances: this is the database half of
# turnkeylinux-apps/mysql, built as a layer on core so that LAMP and any
# other appliance that needs MariaDB is built on it instead of installing
# its own.
#
#     git clone --branch v1.0.0 \
#         https://github.com/keel-linux/unit-mariadb.git unit.d/mariadb
#     bt-layer mariadb --parent core
#
# What it deliberately leaves out, and why, is in README.rst: Adminer needs
# a web server, and which web server differs by context (lighttpd upstream,
# Apache in LAMP), so it arrives with the web stack, not with the database.
#
# The server itself is not included from the shared tree any more. It is the
# unit.d/mariadb component (keel-linux/unit-mariadb), which fab resolves and
# applies on its own and bt-layer records in the layer manifest as
# "units mariadb@<version>", so a layer built on this one applies it once and
# a layer built on that one does not apply it again. Decision 0013 is why:
# a database is a component, LAMP and LAPP share apache-php, and a database
# that is a parent layer cannot be shared that way.

# The recipe's own overlay reaches the tree twice, here and again as
# ROOT_OVERLAY after the units, so a file of this overlay still wins over a
# file of the component. No path is in both today, and tests/unit.bats of
# unit-mariadb lists what the component ships.
COMMON_OVERLAYS += $(CURDIR)/overlay

# Webmin comes from core and answers on 12321; plan/main adds the database
# module for it. Nothing here serves a web page, so 80 and 443 stay shut:
# 3306 is the database, 12321 the panel, 12320 the web shell core carries.
WEBMIN_FW_TCP_INCOMING = 22 3306 12320 12321

include $(FAB_PATH)/common/mk/turnkey.mk

# The project's own packages (inithooks, confconsole, keel) come from the
# build host's APT repository during the build only. The repository is
# copied into the bootstrap and listed as a [trusted=yes] file source,
# because the staging distribution is unsigned; conf.d/main removes both
# from the image and leaves the future apt.keellinux.org entry in place,
# disabled. Same block as keel-nodebb, which is where the pattern is
# maintained.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging

define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo;
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	echo "deb [trusted=yes] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap/etc/apt/sources.list.d/keel-staging.list;
	fab-chroot $O/bootstrap "apt-get update";
endef
bootstrap/post += $(_keel_bootstrap/post)
