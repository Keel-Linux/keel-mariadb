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
# build host's APT repository during the build only. The repository is copied
# into the bootstrap and the build verifies it there, the way an appliance
# verifies the release archive (tracker#7): the public half of the staging key
# is installed as a keyring, the source entry names it through signed-by,
# nothing in the tree says trusted=yes, and apt runs with --error-on=any, so a
# signature that cannot be checked fails the build instead of warning about it
# and carrying on. conf.d/main pins the archive for the build only and
# removes the copy of the archive, the source entry, the pin and the keyring
# from the image. The appliance's own Keel source and pin are common's
# (overlays/turnkey.d/keel-apt).
#
# None of the three build time files is for an installed appliance, because
# the staging key signs whatever the build host produced. The removelist at
# common/removelists-final/turnkey takes all three out of the image as well,
# whatever a recipe does. Same block as keel-nodebb, which is where the pattern is maintained.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging
# Beside the repository rather than inside it: bin/publish of keel-linux/apt
# installs the public half of whichever key it signed a distribution with
# here, so the key a build verifies with cannot drift from the key the archive
# was signed with.
KEEL_APT_KEYRING ?= /srv/keel-apt/keys/keel-staging-keyring.asc
# Where that key goes in the build tree, and which key has to be in it: the
# staging signing subkey (handbook decision 0011). A keyring is only a promise
# until the key inside it is named, so bin/keel-archive-check fails the build
# when the keyring it finds holds some other key.
KEEL_APT_KEYRING_PATH ?= /etc/apt/keyrings/keel-staging-keyring.asc
KEEL_APT_KEY ?= 8CFD1A4841448B2227341CEB202CACBD0E97090A
KEEL_STAGING_LIST ?= /etc/apt/sources.list.d/keel-staging.list
KEEL_ARCHIVE_CHECK = KEEL_ARCHIVE_KEY=$(KEEL_APT_KEY) \
	KEEL_ARCHIVE_KEYRING=$(KEEL_APT_KEYRING_PATH) \
	KEEL_ARCHIVE_LIST=$(KEEL_STAGING_LIST) \
	$(CURDIR)/bin/keel-archive-check $(KEEL_APT_REPO)

# The copy is made fresh and then proved: bin/keel-archive-check compares the
# copied package index with the live one, verifies the signature on the copied
# InRelease against the keyring, refuses any trusted=yes, and stops the build
# when one of them is wrong.
define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo $O/bootstrap$(dir $(KEEL_APT_KEYRING_PATH));
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	install -m 644 $(KEEL_APT_KEYRING) $O/bootstrap$(KEEL_APT_KEYRING_PATH);
	echo "deb [signed-by=$(KEEL_APT_KEYRING_PATH)] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap$(KEEL_STAGING_LIST);
	$(KEEL_ARCHIVE_CHECK) $O/bootstrap $(KEEL_APT_DIST) $(FAB_ARCH) bootstrap;
	fab-chroot $O/bootstrap "apt-get update --error-on=any";
endef
bootstrap/post += $(_keel_bootstrap/post)

# bootstrap is a stamped target, so a second build of the same product reuses
# the copy the first one made and a check in bootstrap/post does not run at
# all. On 2026-09-26 "make clean" failed on a busy deck, the stamps survived,
# and the rebuild installed the packages the archive had held that morning
# without a word. So the tree that is about to be configured is checked on
# every build, whether or not this build made the bootstrap. That check
# verifies the signature with gpgv too, which is what proves this tree at a
# step where no apt-get update runs.
define _keel_root.patched/pre

	$(KEEL_ARCHIVE_CHECK) $O/root.patched $(KEEL_APT_DIST) $(FAB_ARCH) root.patched;
endef
root.patched/pre += $(_keel_root.patched/pre)
