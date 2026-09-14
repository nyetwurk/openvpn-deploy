# OpenVPN

Source of truth for the TUN servers on this NAT router. Edit here.
`/etc/openvpn/server` is the install target. Live daemons are Debian
`openvpn-server@.service` (`WorkingDirectory=/etc/openvpn/server`,
`ProtectHome=true`).

Firewall policy for `tun0` / `tun1` is the sibling nftables tree
(`../nftables`), not this repo.

## Files

- `server-udp.conf` — live UDP unit `openvpn-server@server-udp`. Port
  `1194`, `tun0`, pool `10.8.19.0/24`
- `server-tcp.conf` — live TCP unit `openvpn-server@server-tcp`. Port
  `443`, `tun1`, pool `10.8.20.0/24`. Nothing else may bind `443`
- `server.conf` — Debian 2.6 sample. Not a unit; not installed
- `client.ovpn` — client template (`dev tun`, `block-ipv6`). Placeholders
  `_SERVER_` `_PORT_` `_PROTO_` `_CIPHER_`
- `client-gen` — fills the template from `server-udp.conf` and inlines
  CA, client cert/key, and `ta.key` into `client/$CLIENT.ovpn`
- `easy-rsa/` — Easy-RSA 3. PKI is `easy-rsa/pki/` (gitignored)
- `server/ta.key` — tls-auth key (gitignored)
- `Makefile` — PKI, client profiles, `dryrun`, `install-pki`, `deploy`
- `logrotate.d/openvpn` — rotate `/var/log/openvpn/*.log`
  (`copytruncate`). `ipp` files are not `.log`. Installed to
  `/etc/logrotate.d/openvpn`

Cert paths in the live confs are relative to `/etc/openvpn/server`:

- `ca easy-rsa/pki/ca.crt`
- `cert easy-rsa/pki/issued/vpn.internal.curtisfong.org.crt`
- `key easy-rsa/pki/private/vpn.internal.curtisfong.org.key`
- `dh easy-rsa/pki/dh.pem`
- `tls-auth server/ta.key 0`

Both servers push `redirect-gateway def1 bypass-dhcp`, LAN route
`192.168.19.0/24`, and DNS `192.168.19.1`. Cipher is `AES-256-CBC`.
UDP has `explicit-exit-notify`; TCP does not. Logs and
`ifconfig-pool-persist` are under `/var/log/openvpn/` (unsuffixed for
UDP, `-tcp` for TCP).

The client remote is `vpn.internal.curtisfong.org` (UDP `1194` from
`server-udp.conf`). `verify-x509-name` uses that CN.

## Make

`DEST` defaults to `/etc/openvpn/server`. `SERVER_CN` defaults to
`vpn.internal.curtisfong.org`. `CLIENTS` defaults to `client`.

- `make` / `make all` — `pki` plus `client/$(CLIENTS).ovpn`
- `make pki` — CA, server cert, DH, `server/ta.key` if missing.
  Refuses to run as root
- `make pki-clean` — delete working-tree `easy-rsa/pki`, `server/ta.key`,
  and `client/`. Then `make pki` in a second invocation
- `make clients` / `make client/name.ovpn` — client cert if missing,
  then `client-gen`
- `make dryrun` — `diff -u` live confs against `DEST` and
  `logrotate.d/openvpn` against `/etc/logrotate.d/openvpn`
- `sudo make install-pki` — copy `ca.crt`, server cert/key, `dh.pem`,
  and `ta.key` to `DEST`. Does not copy the CA private key. Does not
  generate; fails if `make pki` has not been run
- `sudo make deploy` — `install-pki`, install the two live confs and
  logrotate, `daemon-reload`, `try-restart` the two units. Does not
  install `server.conf`. Does not enable units

Generate PKI as a normal user, then `sudo make deploy`.

`easy-rsa/pki/`, `server/ta.key`, and `client/*.ovpn` are gitignored.

## Pools

- `tun0` — `10.8.19.0/24` (UDP)
- `tun1` — `10.8.20.0/24` (TCP)

These are not `10.8.0.0/24`. IPv6 is not configured on tun.
