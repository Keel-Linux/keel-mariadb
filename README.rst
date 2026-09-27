keel-mariadb
============

MariaDB database layer for Keel appliances, built on ``core``. Compatible
with TurnKey Linux appliances, and corresponding to the upstream appliance
`turnkeylinux-apps/mysql <https://github.com/turnkeylinux-apps/mysql>`_ for
the database half of what that appliance is::

    git clone --branch v1.0.0 \
        https://github.com/keel-linux/unit-mariadb.git unit.d/mariadb
    bt-layer mariadb --parent core

The server comes from the ``unit.d/mariadb`` component, not from the shared
tree: `keel-linux/unit-mariadb
<https://github.com/keel-linux/unit-mariadb>`_ carries its plan, its overlay
and its conf script, fab applies it, and ``bt-layer`` records it in the layer
manifest as ``units mariadb@1.0.0``. Materialising ``unit.d`` from the pin is
the assembly step decision 0010 names as work of the project and does not
exist yet, so the clone above is that step for now; ``unit.d/`` is ignored by
git here.

It is a layer, not a product: LAMP and any other appliance that needs
MariaDB is built on it, so the server is fetched, secured and measured
once. Nothing is stopping it being run on its own; it boots, it listens on
loopback, and Webmin administers it.

What is in it
-------------

======================================  ====================================
``Makefile``                            the component under ``unit.d``, this overlay, the firewall ports
``plan/main``                           the client and the project packages; MariaDB, python3-pymysql and webmin-mysql are the component's plan
``conf.d/main``                         the administrative account, created unusable; the checks; the project package upgrade
``overlay/etc/mysql/mariadb.conf.d/``   the bind addresses: ``::1`` and ``127.0.0.1``
``overlay/usr/lib/inithooks/``          the first boot hook, its library and its dialog
``keel/instance.example.yaml``          the instance description an operator starts from
``tests/``                              bats for the shell, ``boot-test.sh`` for the machine
======================================  ====================================

Webmin comes from ``core`` and answers on 12321; this layer adds
``webmin-mysql``, the module that puts the database in it. Batteries
included is a property of this distribution, so the boot test checks both
the module and the panel.

What it deliberately leaves out
-------------------------------

Upstream's ``mysql`` appliance also bundles **Adminer**, **lighttpd** and
**php-fpm**, and a landing page served by them. None of that is here.

Adminer needs a web server, and which web server differs by context:
lighttpd in the upstream appliance, Apache in LAMP and LAPP. Putting it in
the database layer forces a choice that the layers above would have to
undo and make again. So Adminer arrives with the web stack, in LAMP and
LAPP, which is also where upstream puts it for those products.

The database is also **not opened to the network**. Upstream's ``mysql``
appliance opens 3306 and upstream's ``postgresql`` appliance goes further
and accepts password authentication from anywhere. This layer listens on
``::1`` and ``127.0.0.1``, because it exists to be built on and the
appliance above it is on the same machine. An appliance that really has
remote clients opens the port, says who may connect and terminates TLS.
That is a decision an appliance makes, not one a database layer makes for
every appliance built on it.

If the maintainer later wants literal parity with the upstream ``mysql``
appliance, that is a different artefact: the appliance, built on this
layer, with Adminer and a web server of its own.

The password, and the defect these layers exposed
-------------------------------------------------

An instance description declares the database password once::

    secrets:
      db_password:
        file: /etc/keel/secrets/db_password

That renders to ``DB_PASS`` (``SECRET_VARS``, the same table in
``keel/spec/constants.py`` and in ``libinithooks/declarative.py`` of the
inithooks fork), and ``DB_PASS`` is what every database hook ``common``
ships already reads: ``overlays/pgsql`` ``firstboot.d/35pgsqlpass`` and
``overlays/adminer`` ``firstboot.d/35adminer-mysqlpass``.

On the MariaDB side there was no hook to read it. The only one that calls
``bin/mysqlconf.py`` ships in the **Adminer** overlay, together with the
account it configures, which this layer leaves out. So a declared database
password reached nothing on an appliance whose whole purpose is the
database: the first boot would have asked, or left the account as the
build made it, and the operator would have found out by trying to connect.

The repair is here, in the layer, not in the renderer.
``overlay/usr/lib/inithooks/firstboot.d/35mysqlpass`` reads ``DB_PASS`` at
the position upstream uses, hands it to the shared ``bin/mysqlconf.py``
for each host of the administrative account, and then connects as a client
to say whether it worked. ``MYSQL_PASS``, which ``mk/turnkey/mysql.mk``
adds to ``CONF_VARS``, is a build time variable fab passes to the conf
scripts inside the chroot; it never reaches the inithooks conf and nothing
reads it there.

The administrative account is ``admin``, created by ``conf.d/main`` with a
hash no input produces, so it authenticates nothing until the first boot
sets it. A layer is published once and reused, so a password chosen at
build time would be the same on every appliance built from it, and a
random one would make the layer irreproducible.

Tests
-----

``tests/README.md`` has the detail. In short: ``tests/coverage.sh`` runs
the bats suite under kcov and gates the shell this layer writes;
``tests/boot-test.sh`` assembles the published layer, boots it headless
from an instance description that declares ``secrets.db_password`` from a
file, connects to the database with that password, checks the Webmin
module and Webmin over IPv6, and runs ``keel diff``.
