# keel-mariadb: MariaDB, the Webmin module for it, and nothing else.
# Compatible with TurnKey Linux appliances: this is the database half of
# turnkeylinux-apps/mysql, built as a layer on core so that LAMP and any
# other appliance that needs MariaDB is built on it instead of installing
# its own.
#
#     bt-layer mariadb --parent core
#
# What it deliberately leaves out, and why, is in README.rst: Adminer needs
# a web server, and which web server differs by context (lighttpd upstream,
# Apache in LAMP), so it arrives with the web stack, not with the database.

include $(FAB_PATH)/common/mk/turnkey/mysql.mk

# After mysql.mk, so a file of this overlay wins over the shared one.
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
