# OpenVPN

Source of truth for the TUN servers on this NAT router. Edit here.
`/etc/openvpn/server` is the install target. Live daemons are Debian
`openvpn-server@.service` (`WorkingDirectory=/etc/openvpn/server`,
`ProtectHome=true`). Units: `openvpn-server@server-udp` and
`openvpn-server@server-tcp`.

Firewall policy for `tun0` / `tun1` is the sibling nftables tree
(`../nftables`), not this repo.

## Files

- `server-udp.conf` — live UDP unit `openvpn-server@server-udp`. Port
  `1194`, `tun0`, pool `10.8.19.0/24`. Day-to-day profile
- `server-tcp.conf` — live TCP unit `openvpn-server@server-tcp`. Port
  `443`, `tun1`, pool `10.8.20.0/24`. Hotel/guest-wifi fallback.
  `port-share 127.0.0.1 8443` sends non-OpenVPN TCP (HTTPS) to Apache.
  Apache must not `Listen 443`.
- `server.conf` — Debian sample. Not a unit; not installed
- `client.ovpn` — client template (`dev tun`, `block-ipv6`, `mssfix
  1360`). Placeholders `_SERVER_` `_PORT_` `_PROTO_` `_CIPHER_`
- `client-gen` — fills the template from a live server conf and inlines
  CA, client cert/key, and `ta.key`. UDP → `client/$CLIENT.ovpn`; TCP →
  `client/$CLIENT.tcp.ovpn` (same cert)
- `easy-rsa/` — Easy-RSA 3. PKI is `easy-rsa/pki/` (gitignored)
- `server/ta.key` — tls-auth key (gitignored)
- `Makefile` — PKI, client profiles, `dryrun`, `install-pki`, `deploy`
- `logrotate.d/openvpn` — `/var/log/openvpn/*.log` (`copytruncate`,
  `create 0640 root adm`). `ipp` files are not `.log`. Installed to
  `/etc/logrotate.d/openvpn`

Cert paths in the live confs are relative to `/etc/openvpn/server`:

- `ca easy-rsa/pki/ca.crt`
- `cert easy-rsa/pki/issued/vpn.internal.curtisfong.org.crt`
- `key easy-rsa/pki/private/vpn.internal.curtisfong.org.key`
- `dh easy-rsa/pki/dh.pem`
- `tls-auth server/ta.key 0`

Both servers push `redirect-gateway def1 bypass-dhcp`, LAN route
`192.168.19.0/24`, and DNS `192.168.19.1`. Cipher is `AES-256-CBC`.
UDP has `explicit-exit-notify`. Both have `mssfix 1360`. Do not use
`fragment` (OpenVPN Connect on Android trips `FRAG_IN` on the server).
Logs and `ifconfig-pool-persist` are under `/var/log/openvpn/`
(unsuffixed for UDP, `-tcp` for TCP). OpenVPN creates those files
`0600` root; there is no `--log-mode`.

The client remote is `vpn.internal.curtisfong.org`. UDP profiles use
port `1194`; TCP profiles use `443`. `verify-x509-name` uses that CN.
Import one `.ovpn` per device in OpenVPN Connect. Do not run UDP and
TCP profiles at the same time. UDP is the daily transport; TCP is only
when UDP is blocked.

A LAN host connecting to the WAN IP is local INPUT on this box (no
DNAT hairpin). `push "route 192.168.19.0/24"` then sends other LAN
traffic through the tun.

## Make

`DEST` defaults to `/etc/openvpn/server`. `SERVER_CN` defaults to
`vpn.internal.curtisfong.org`. `CLIENTS` defaults to `id -un` (or
`SUDO_USER` if make is root).

- `make` / `make all` — `pki` plus UDP and TCP profiles for `$(CLIENTS)`
- `make pki` — CA, server cert, DH, `server/ta.key` if missing.
  Refuses to run as root
- `make pki-clean` — delete working-tree `easy-rsa/pki`, `server/ta.key`,
  and `client/`. Then `make pki` in a second invocation
- `make clients` — `client/name.ovpn` and `client/name.tcp.ovpn` for
  each name in `CLIENTS` (cert if missing)
- `make client/name.ovpn` — UDP profile from `server-udp.conf`
- `make client/name.tcp.ovpn` — same cert, TCP `443` from
  `server-tcp.conf`
- `make dryrun` — `diff -u` live confs against `DEST` and
  `logrotate.d/openvpn` against `/etc/logrotate.d/openvpn`
- `sudo make install-pki` — copy `ca.crt`, server cert/key, `dh.pem`,
  and `ta.key` to `DEST`. Does not copy the CA private key. Does not
  generate; fails if `make pki` has not been run
- `sudo make deploy` — `install-pki`, install the two live confs and
  logrotate, `daemon-reload`, `try-restart` the two units. Does not
  install `server.conf`. Does not enable units

Generate PKI as a normal user, then `sudo make deploy`. Enable units
on the host (`systemctl enable --now openvpn-server@server-udp
openvpn-server@server-tcp`).

`easy-rsa/pki/`, `server/ta.key`, and `client/*.ovpn` are gitignored.

## Pools

- `tun0` — `10.8.19.0/24` (UDP)
- `tun1` — `10.8.20.0/24` (TCP)

These are not `10.8.0.0/24`. IPv6 is not configured on tun. Clients
`block-ipv6`.
