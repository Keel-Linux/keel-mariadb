# Evidence: mariadb.socket closed on the pair test nodes, 2026-10-09

Issue #29 (finding B3 of Keel-Linux/handbook#60,
docs/evidence/2026-10-08-mariadb-pair-real.md). This file records the
mitigation on the two test containers. Public uplink addresses are
replaced by `<uplink>`. In a line with two `<uplink>`, the first is db-1
and the second is db-2.

## Nodes

- Proxmox VE host: hw12-br1. Commands with `[host]` ran on the host.
- CT 9003 keel-db-1: replica, keel 0.23.3, overlay address
  fd11:a58a:88ef:0:382f:45b:553c:f11.
- CT 9004 keel-db-2: primary, keel 0.23.3, overlay address
  fd11:a58a:88ef:0:cd53:dda9:f0cb:b889, holds the VIP
  fd11:a58a:88ef::ffff:1.
- No other container was touched.

## Cause

`mariadb.socket` of Debian's mariadb-server 1:11.8.6-0+deb13u1 has
`ListenStream=3306`. systemd binds this as `[::]:3306`. Debian's package
does not enable the unit (debian/rules installs only mariadb.service with
dh_installsystemd). But `pct create` removes /etc/machine-id
(PVE::LXC::Setup::Base, clear_machine_id), so the first start of the
container is the first boot of systemd. On a first boot, systemd enables
all units that no preset disables. On CT 9003 the links in
/etc/systemd/system/sockets.target.wants have the time of the first boot
(2026-10-08 19:42:06, the same time as /etc/machine-id): mariadb.socket,
mariadb-extra.socket, ssh.socket, acpid.service and others. The image of
2026-10-07 did not have them.

With the socket active, mariadbd gets the listener from systemd, and the
`bind-address` of 99-keel-database.cnf has no effect.

## Procedure

1. Record the state before the change: replication, listeners, keel diff,
   and a TCP probe from the host to 3306 on both uplinks.
2. Replica first (CT 9003): `systemctl disable --now` for both socket
   units, then `systemctl mask` for both. mariadb.service does not require
   the sockets, so it continues to run. Then restart mariadb.service, so
   that mariadbd opens its own listeners from bind-address.
3. Make sure that replication runs again (IO Yes, SQL Yes, TLS, lag 0).
4. Primary (CT 9004): the same steps. The restart is a planned gap. The
   role drop-in starts the server read only, so `keel database follow`
   sets read_only OFF at once. Measured gap: 00:09:17.59 (restart start) to
   00:09:19.30 (read_only 0), approximately 1.7 s.
5. Write a row on the primary and read it on the replica.
6. From the host: 3306 on both uplinks is closed (connection refused).
7. From the overlay (CT 9003 over wg0): the VIP answers on 3306, as
   keel-db-2, read_only 0.
8. `keel diff` on both nodes: `database.server.listen: same`.

The sysctl `net.ipv6.ip_nonlocal_bind = 1` is persistent
(/etc/sysctl.d/90-keel-database.conf, written by keel), so the server can
bind the VIP and the overlay address at the next boot without the socket.
A reboot of the nodes was not done in this test.

## Result

| Check | Before | After |
| --- | --- | --- |
| Listener on 3306, db-1 | `*:3306` (mariadbd and systemd) | `[::1]`, overlay address, VIP |
| Listener on 3306, db-2 | `*:3306` (mariadbd and systemd) | `[::1]`, overlay address, VIP |
| TCP from host to uplink:3306, db-1 | OPEN | Connection refused |
| TCP from host to uplink:3306, db-2 | OPEN | Connection refused |
| VIP:3306 from db-1 over wg0 | answers | answers (keel-db-2, read_only 0) |
| Replication | IO Yes, SQL Yes, TLS Yes, lag 0 | IO Yes, SQL Yes, TLS Yes, lag 0 |
| Semi-synchronous on the primary | ON, 1 client | ON, 1 client |
| `keel diff`, database.server.listen | drift (observed `*`) | same |
| mariadb.socket, mariadb-extra.socket | enabled, active | masked, inactive |

The IPv4 probes to 10.88.5.209 and 10.88.5.213 gave "No route to host"
from the host. They do not prove a closed port. `ss` shows no IPv4 and no
wildcard listener on 3306 after the change.

## Commands and outputs

The output of each command is as it came, except for the uplink
addresses.

```text
=== [9003] 2026-10-09T00:05:41Z rc=0
$ mariadb -e "SHOW REPLICA STATUS\G" | grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind|Master_SSL_Allowed|Gtid_IO_Pos|Last_.*Error:"; mariadb -N -e "select @@read_only, @@gtid_current_pos"
                   Master_Host: fd11:a58a:88ef:0:cd53:dda9:f0cb:b889
              Slave_IO_Running: Yes
             Slave_SQL_Running: Yes
                    Last_Error: 
            Master_SSL_Allowed: Yes
         Seconds_Behind_Master: 0
                 Last_IO_Error: 
                Last_SQL_Error: 
                   Gtid_IO_Pos: 0-650213503-1744
       Slave_SQL_Running_State: Slave has read all relay log; waiting for more updates
1	0-650213503-1744

=== [9004] 2026-10-09T00:08:21Z rc=0
$ mariadb -N -e 'select @@read_only, @@gtid_current_pos; show status like "Rpl_semi_sync_master_c%"; show status like "Rpl_semi_sync_master_status"'
0	0-650213503-1744
Rpl_semi_sync_master_clients	1
Rpl_semi_sync_master_status	ON

=== [9003] 2026-10-09T00:08:29Z rc=0
$ ss -ltnp | grep 3306; systemctl list-sockets --no-legend | grep -E "maria"; keel diff 2>&1 | grep -E "^database"
LISTEN 0      4096                                          *:3306             *:*    users:(("mariadbd",pid=481,fd=7),("systemd",pid=1,fd=62))
@mariadb                            mariadb.socket                  mariadb.service
@mariadb-extra                      mariadb-extra.socket            mariadb.service
[::]:3306                           mariadb.socket                  mariadb.service
/run/mysqld/mysqld.sock             mariadb.socket                  mariadb.service
/run/mysqld/mysqld.sock-extra       mariadb-extra.socket            mariadb.service
database.server.engine: same (mariadb)
database.server.role: not compared (the role is runtime state on a paired node (appliance.vip, decisions 0020 and 0049): the VIP makes this node the replica, the server is a replica, and the declared primary is the installation's; nothing converges it)
database.server.listen: drift (declared fd11:a58a:88ef:0:382f:45b:553c:f11, ::1, observed *)
database.server.replication.primary.host: not declared (observed fd11:a58a:88ef:0:cd53:dda9:f0cb:b889)
database.server.replication.primary.port: not declared (observed 3306)
database.server.read_only: same (true)
database.server.semi_sync: not compared (compared on the primary, whose commits wait for the replica; this node is the replica)

=== [9004] 2026-10-09T00:08:32Z rc=0
$ ss -ltnp | grep 3306; systemctl list-sockets --no-legend | grep -E "maria"; keel diff 2>&1 | grep -E "^database"
LISTEN 0      4096                                            *:3306             *:*    users:(("mariadbd",pid=479,fd=5),("systemd",pid=1,fd=66))
@mariadb                            mariadb.socket                  mariadb.service
@mariadb-extra                      mariadb-extra.socket            mariadb.service
[::]:3306                           mariadb.socket                  mariadb.service
/run/mysqld/mysqld.sock             mariadb.socket                  mariadb.service
/run/mysqld/mysqld.sock-extra       mariadb-extra.socket            mariadb.service
database.server.engine: same (mariadb)
database.server.role: not compared (the role is runtime state on a paired node (appliance.vip, decisions 0020 and 0049): the VIP makes this node the primary, the server is a primary, and the declared replica is the installation's; nothing converges it)
database.server.listen: drift (declared fd11:a58a:88ef:0:cd53:dda9:f0cb:b889, ::1, observed *)
database.server.replication.allowed_from: not declared (observed fd11:a58a:88ef:0:382f:45b:553c:f11)
database.server.read_only: same (false)
database.server.semi_sync: same (on)

=== [host] 2026-10-09T00:08:34Z rc=0
$ for a in <uplink> <uplink>; do timeout 5 bash -c "</dev/tcp/$a/3306" 2>&1 && echo "3306 OPEN on [$a]" || echo "3306 closed on [$a]"; done
3306 OPEN on [<uplink>]
3306 OPEN on [<uplink>]

=== [9003] 2026-10-09T00:08:41Z rc=0
$ systemctl disable --now mariadb.socket mariadb-extra.socket; systemctl mask mariadb.socket mariadb-extra.socket; systemctl is-active mariadb.service; systemctl is-enabled mariadb.socket mariadb-extra.socket mariadb.service
Removed '/etc/systemd/system/sockets.target.wants/mariadb.socket'.
Removed '/etc/systemd/system/sockets.target.wants/mariadb-extra.socket'.
Created symlink '/etc/systemd/system/mariadb.socket' → '/dev/null'.
Created symlink '/etc/systemd/system/mariadb-extra.socket' → '/dev/null'.
active
masked
masked
enabled

=== [9003] 2026-10-09T00:08:43Z rc=0
$ systemctl restart mariadb.service; systemctl is-active mariadb.service; ss -ltnp | grep 3306; ls -l /run/mysqld/
active
LISTEN 0      80                                        [::1]:3306          [::]:*    users:(("mariadbd",pid=6222,fd=34))                  
LISTEN 0      80                     [fd11:a58a:88ef::ffff:1]:3306          [::]:*    users:(("mariadbd",pid=6222,fd=35))                  
LISTEN 0      80         [fd11:a58a:88ef:0:382f:45b:553c:f11]:3306          [::]:*    users:(("mariadbd",pid=6222,fd=33))                  
total 4
-rw-rw---- 1 mysql mysql 5 Oct  9 00:08 mysqld.pid
srwxrwxrwx 1 mysql mysql 0 Oct  9 00:08 mysqld.sock
srw-rw-rw- 1 root  root  0 Oct  8 23:57 mysqld.sock-extra

=== [9003] 2026-10-09T00:08:57Z rc=0
$ mariadb -e "SHOW REPLICA STATUS\G" | grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running:|Seconds_Behind|Master_SSL_Allowed|Gtid_IO_Pos|Last_IO_Error|Last_SQL_Error"; mariadb -N -e "select @@read_only, @@gtid_current_pos"
                   Master_Host: fd11:a58a:88ef:0:cd53:dda9:f0cb:b889
              Slave_IO_Running: Yes
             Slave_SQL_Running: Yes
            Master_SSL_Allowed: Yes
         Seconds_Behind_Master: 0
                 Last_IO_Error: 
                Last_SQL_Error: 
                   Gtid_IO_Pos: 0-650213503-1744
1	0-650213503-1744

=== [9004] 2026-10-09T00:08:58Z rc=0
$ mariadb -N -e 'show status like "Rpl_semi_sync_master_clients"; show status like "Rpl_semi_sync_master_status"; select @@gtid_current_pos'
Rpl_semi_sync_master_clients	1
Rpl_semi_sync_master_status	ON
0-650213503-1744

=== [host] 2026-10-09T00:09:00Z rc=0
$ timeout 5 bash -c "</dev/tcp/<uplink>/3306" 2>&1 && echo "3306 OPEN on db-1 uplink" || echo "3306 closed on db-1 uplink"
bash: connect: Connection refused
bash: line 1: /dev/tcp/<uplink>/3306: Connection refused
3306 closed on db-1 uplink

=== [9004] 2026-10-09T00:09:13Z rc=0
$ systemctl disable --now mariadb.socket mariadb-extra.socket; systemctl mask mariadb.socket mariadb-extra.socket; systemctl is-active mariadb.service; systemctl is-enabled mariadb.socket mariadb-extra.socket mariadb.service
Removed '/etc/systemd/system/sockets.target.wants/mariadb.socket'.
Removed '/etc/systemd/system/sockets.target.wants/mariadb-extra.socket'.
Created symlink '/etc/systemd/system/mariadb.socket' → '/dev/null'.
Created symlink '/etc/systemd/system/mariadb-extra.socket' → '/dev/null'.
active
masked
masked
enabled

=== [9004] 2026-10-09T00:09:16Z rc=0
$ date -u +%T.%N; systemctl restart mariadb.service; date -u +%T.%N; mariadb -N -e "select @@read_only"; keel database follow; date -u +%T.%N; mariadb -N -e "select @@read_only"; ss -ltnp | grep 3306
00:09:17.588645770
00:09:18.436233543
1
database.server.role: set read_only OFF: this role takes the application's writes
00:09:19.304315835
0
LISTEN 0      80         [fd11:a58a:88ef:0:cd53:dda9:f0cb:b889]:3306          [::]:*    users:(("mariadbd",pid=9195,fd=33))                  
LISTEN 0      80                       [fd11:a58a:88ef::ffff:1]:3306          [::]:*    users:(("mariadbd",pid=9195,fd=35))                  
LISTEN 0      80                                          [::1]:3306          [::]:*    users:(("mariadbd",pid=9195,fd=34))                  

=== [9004] 2026-10-09T00:09:39Z rc=0
$ mariadb -N -e 'show status like "Rpl_semi_sync_master_clients"; show status like "Rpl_semi_sync_master_status"; create table if not exists keeltest.socket29 (id int primary key, at timestamp default current_timestamp); replace into keeltest.socket29 (id) values (29); select @@gtid_current_pos'
Rpl_semi_sync_master_clients	1
Rpl_semi_sync_master_status	ON
0-650213503-1746

=== [9003] 2026-10-09T00:09:43Z rc=0
$ mariadb -e "SHOW REPLICA STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running:|Seconds_Behind|Master_SSL_Allowed|Last_IO_Error|Last_SQL_Error"; mariadb -N -e "select @@gtid_current_pos; select id, at from keeltest.socket29"
              Slave_IO_Running: Yes
             Slave_SQL_Running: Yes
            Master_SSL_Allowed: Yes
         Seconds_Behind_Master: 0
                 Last_IO_Error: 
                Last_SQL_Error: 
0-650213503-1746
29	2026-10-09 00:09:41

=== [host] 2026-10-09T00:09:44Z rc=0
$ for a in <uplink> <uplink>; do timeout 5 bash -c "</dev/tcp/$a/3306" 2>&1 && echo "3306 OPEN on [$a]" || echo "3306 closed on [$a]"; done
bash: connect: Connection refused
bash: line 1: /dev/tcp/<uplink>/3306: Connection refused
3306 closed on [<uplink>]
bash: connect: Connection refused
bash: line 1: /dev/tcp/<uplink>/3306: Connection refused
3306 closed on [<uplink>]

=== [9003] 2026-10-09T00:09:45Z rc=0
$ timeout 5 bash -c "</dev/tcp/fd11:a58a:88ef::ffff:1/3306" && echo "VIP 3306 answers over wg0"; ip -6 route get fd11:a58a:88ef::ffff:1; mariadb --defaults-extra-file=/root/.app.cnf -h fd11:a58a:88ef::ffff:1 -N -e "select @@hostname, @@read_only"
VIP 3306 answers over wg0
fd11:a58a:88ef::ffff:1 from :: dev wg0 proto kernel src fd11:a58a:88ef:0:382f:45b:553c:f11 metric 256 pref medium
keel-db-2	0

=== [9003] 2026-10-09T00:09:52Z rc=1
$ ip -4 -br addr show eth0; keel diff 2>&1 | grep -E "^database.server.listen"; systemctl list-sockets --no-legend | grep -c maria
eth0@if109       UP             10.88.5.209/24 
database.server.listen: same (fd11:a58a:88ef:0:382f:45b:553c:f11, ::1)
0

=== [9004] 2026-10-09T00:09:54Z rc=1
$ ip -4 -br addr show eth0; keel diff 2>&1 | grep -E "^database.server.listen"; systemctl list-sockets --no-legend | grep -c maria
eth0@if105       UP             10.88.5.213/24 
database.server.listen: same (fd11:a58a:88ef:0:cd53:dda9:f0cb:b889, ::1)
0

=== [host] 2026-10-09T00:10:01Z rc=0
$ for a in 10.88.5.209 10.88.5.213; do timeout 5 bash -c "</dev/tcp/$a/3306" 2>&1 && echo "3306 OPEN on $a" || echo "3306 closed on $a"; done
bash: connect: No route to host
bash: line 1: /dev/tcp/10.88.5.209/3306: No route to host
3306 closed on 10.88.5.209
bash: connect: No route to host
bash: line 1: /dev/tcp/10.88.5.213/3306: No route to host
3306 closed on 10.88.5.213

```
