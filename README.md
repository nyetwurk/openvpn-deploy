# OpenVPN

Source of truth for the TUN servers on this NAT router. Edit here.
`/etc/openvpn/server` is the install target (`DEST`): confs and PKI
only. Live daemons are Debian `openvpn-server@.service`
(`WorkingDirectory=/etc/openvpn/server`, `ProtectHome=true`). Units:
`openvpn-server@server-udp` and `openvpn-server@server-tcp` when those
listeners are enabled. Pool persist is `/var/lib/openvpn-server/`
(daemon-written, `nobody:adm` `0640`). Status is `/run/openvpn-server/`
(tmpfs; Debian `0710` root; `sudo cat`).

Firewall policy for the TUN devices on the NAT router is the sibling
nftables tree (`../nftables`), not this repo. If you change `UDP_DEV` /
`TCP_DEV` or the VPN pools, update that tree too.

A WAN-only host (no LAN, no masquerade) should not use that tree. Copy
`examples/50-openvpn.nft` into that host's `/etc/nftables.d/`. It owns
`table ip openvpn` (does not use `ip filter` / `ip nat`). Copy
`examples/99-openvpn-forward.conf` into `/etc/sysctl.d/` and run
`sysctl --system`. `make deploy` does not install nft or sysctl. Skip
the sysctl file on the NAT router if LAN masquerade already forwards.
If Debian `inet filter` forward policy is drop, accept the VPN traffic
there too. Debian `openvpn-server@.service` sets `LimitNPROC`; that can
fail in a VM or container (`systemd-detect-virt`). If the unit fails to
start, add a drop-in with `[Service]` / `LimitNPROC=infinity`. Skip that
on the NAT router. `make deploy` does not install it.

## Configuration

Site overrides live in `config.mk` (gitignored). Defaults are in the
Makefile. Copy the example and uncomment only what you change, or
write a short `config.mk` with just those lines:

```sh
cp examples/config.mk config.mk
```

`make` works without `config.mk`. `make VAR=...` still overrides.

`config.mk` is the place for identity, listeners, and the networks
pushed to clients. Left as constants: `user nobody` / `group nogroup`,
`keepalive`, `topology subnet`, persist flags, and the Debian sample
`server.conf`.

| Variable | Role |
| --- | --- |
| `SERVER_CN` | Server cert CN; client `verify-x509-name` |
| `REMOTE` | Client `remote` hostname (defaults to `SERVER_CN`) |
| `ENABLE_UDP` / `ENABLE_TCP` | `yes` to build, install, and restart that unit (TCP defaults to `no`) |
| `UDP_PORT` / `TCP_PORT` | Listen ports |
| `UDP_DEV` / `TCP_DEV` | TUN devices (`tun0` / `tun1`) |
| `UDP_POOL` / `TCP_POOL` | VPN pools (`address netmask`) |
| `LAN_ROUTE` / `DNS` | Pushed LAN route and DNS; empty = omit. `DNS` also pushes `block-outside-dns` |
| `CIPHER` | Optional `data-ciphers-fallback`; empty = OpenVPN 2.6 GCM |
| `MSSFIX` | MSS clamp |
| `REDIRECT_GATEWAY` | Full-tunnel push; empty = split tunnel |
| `PORT_SHARE` | TCP non-OpenVPN forward (`host port`); empty / default = off |
| `DEST` / `CLIENTS` | Install dir and profile names (already make vars) |
| `STATE_DIR` | Pool-persist directory (`/var/lib/openvpn-server`) |
| `UDP_IPP` / `TCP_IPP` | `ifconfig-pool-persist` paths under `STATE_DIR` |
| `CERT_DAYS` | Lifetime for **new** CA/server/client certs (`3650`) |

Changing `SERVER_CN` after `make pki` needs a new server cert. Disabling
a listener does not stop a unit already enabled on the host.

Live `server-udp.conf` and `server-tcp.conf` are generated from
`server.conf.in` (`make confs`). Do not edit the generated files.
Templates use `@NAME@` placeholders. `subst` expands them from
`NAME=value` arguments (or the environment) and fails if a name is
unset or left over.

## Files

- `examples/config.mk` — commented override list (defaults are in the
  Makefile). Copy to `config.mk` at the repo root and uncomment what
  you change
- `config.mk` — local overrides (gitignored as `/config.mk`)
- `server.conf.in` — live unit template (UDP and TCP). Does not
  generate the Debian `server.conf` sample
- `server-udp.conf` / `server-tcp.conf` — generated. UDP is the
  day-to-day profile; TCP is off unless `ENABLE_TCP=yes` (hotel /
  guest-wifi fallback). `PORT_SHARE` is off unless set (e.g.
  `127.0.0.1 8443` to Apache). Apache must not `Listen` on `TCP_PORT`
  when `PORT_SHARE` is set
- `server.conf` — Debian sample. Not a unit; not installed
- `client.ovpn.in` — client template (`dev tun`, `block-ipv6`,
  `ignore-unknown-option block-outside-dns`). Placeholders `@SERVER@`
  `@REMOTE@` `@PORT@` `@PROTO@` `@MSSFIX@`
- `subst` — `subst TEMPLATE [NAME=value ...]`. Shared `@NAME@`
  expander for `server.conf.in` and `client.ovpn.in`
- `client-gen` — `client-gen SERVER_CN [CLIENT [CONF [OUT]]]`. Runs
  `subst` on `client.ovpn.in` using port/proto/mssfix from a
  generated server conf, then inlines CA, client cert/key, and
  `tc.key`. Fails if `SERVER_CN` is omitted. UDP →
  `client/$CLIENT.ovpn`; TCP → `client/$CLIENT.tcp.ovpn` (same cert)
- `easy-rsa/` — PKI working dir (`pki/` is gitignored), plus `vars` and
  `openssl-easyrsa.cnf`. Not a full Easy-RSA checkout. Needs Debian
  `easy-rsa` (`apt install easy-rsa`)
- `tc.key` — tls-crypt key (gitignored)
- `Makefile` — PKI, client profiles, `confs`, `dryrun`, `install-pki`,
  `deploy`
- `examples/50-openvpn.nft` — WAN-only host fragment. Copy to that
  host's `/etc/nftables.d/`. Not installed. Do not use on the NAT router
- `examples/99-openvpn-forward.conf` — WAN-only `ip_forward`. Copy to
  that host's `/etc/sysctl.d/`, then `sysctl --system`. Not installed.
  Skip on the NAT router if LAN masquerade already forwards

Cert paths in the live confs are relative to `/etc/openvpn/server`:

- `ca easy-rsa/pki/ca.crt`
- `cert easy-rsa/pki/issued/$(SERVER_CN).crt`
- `key easy-rsa/pki/private/$(SERVER_CN).key`
- `dh none`
- `tls-crypt tc.key`
- `crl-verify crl.pem`

Defaults push `redirect-gateway def1 bypass-dhcp`. `LAN_ROUTE` and
`DNS` are omitted unless set in `config.mk`. When `DNS` is set, the
server also pushes `block-outside-dns` (Windows leak; no-op on
Linux/Android if the client has `ignore-unknown-option`). Data cipher is
the OpenVPN 2.6 default (AES-GCM). Optional `CIPHER` sets
`data-ciphers-fallback` for old clients. `tls-version-min 1.2`. `dh none`
(ECDHE; no `gen-dh`). `tls-crypt` (no `tls-auth` / `key-direction`).
`crl-verify crl.pem` (`0644` in `DEST`; `make revoke CLIENT=name` then
`sudo make deploy`). UDP has `explicit-exit-notify`. Both have
`mssfix 1360`.
Do not use `fragment` (OpenVPN Connect on Android trips `FRAG_IN` on
the server). No `log` / `log-append` and no `verb` on the server
(OpenVPN default is 1). Client profiles use `verb 3`. The units stay in the foreground; journald takes stdout
(`journalctl -u openvpn-server@server-udp` /
`openvpn-server@server-tcp`). The stock unit already passes
`--suppress-timestamps` and `--status
/run/openvpn-server/status-%i.log` (`--status-version 2`). Do not set
`status` in the confs (that overrides the unit path). `/run` is tmpfs;
status is live-only (`0710` root; `sudo cat` to read).
`ifconfig-pool-persist` is `/var/lib/openvpn-server/ipp.txt` (UDP) and
`ipp-tcp.txt` (TCP). Persist across reboot; not a log; not under
`DEST`. `make deploy` creates the directory `0750` `nobody:adm`
and the persist files `0640` if missing (does not truncate existing
files). Members of `adm` can read them; the process stays
`group nogroup`. Copy old `/var/log/openvpn/ipp*.txt` into `STATE_DIR`
by hand if you still need those assignments. Do not use the legacy
`openvpn@` template
(`/etc/openvpn/%i.conf`). TCP `port-share` still logs non-OpenVPN
accepts at verb 1; that is expected, not a VPN client.

The client remote defaults to `SERVER_CN`
(`example.com`). UDP profiles use `UDP_PORT` (`1194`);
TCP profiles use `TCP_PORT` (`443`). `verify-x509-name` uses
`SERVER_CN`. Profiles are mode `0600` (they inline the client private
key). Import one `.ovpn` per device in OpenVPN Connect. Do not
run UDP and TCP profiles at the same time. UDP is the daily transport;
TCP is only when UDP is blocked. Switching `tls-crypt` needs new
profiles; old `tls-auth` `.ovpn` will not connect.

A LAN host connecting to the WAN IP is local INPUT on this box (no
DNAT hairpin). When `LAN_ROUTE` is set, that push sends other LAN
traffic through the tun.

## Make

`DEST` defaults to `/etc/openvpn/server`. `SERVER_CN` defaults to
`example.com`. `CLIENTS` defaults to `id -un` (or
`SUDO_USER` if make is root). `EASYRSA` defaults to
`/usr/share/easy-rsa/easyrsa` (`apt install easy-rsa`). Uncomment those
in `config.mk` to override.

- `make` / `make all` — `confs`, `pki`, and profiles for `$(CLIENTS)`
- `make confs` — generate enabled `server-udp.conf` / `server-tcp.conf`
- `make pki` — CA, server cert, `tc.key`, initial CRL if missing.
  Refuses to run as root. Does not run `gen-dh`. Requires `easy-rsa`.
  New certs use `CERT_DAYS` (3650); does not reissue existing certs
- `make pki-clean` — delete working-tree `easy-rsa/pki`, `tc.key`,
  and `client/`. Then `make pki` in a second invocation
- `make revoke CLIENT=name` — revoke that client cert and regenerate
  `pki/crl.pem`. Does not copy the CA key. Then `sudo make deploy`
- `make clients` — `client/name.ovpn` and/or `client/name.tcp.ovpn` for
  each name in `CLIENTS` (cert if missing; skipped if that proto is off)
- `make client/name.ovpn` — UDP profile from `server-udp.conf`
- `make client/name.tcp.ovpn` — same cert, TCP from `server-tcp.conf`
- `make dryrun` — `diff -u` live confs against `DEST`
- `sudo make install-pki` — copy `ca.crt`, server cert/key,
  `tc.key`, and `crl.pem` to `DEST`. Does not copy the CA private key
  or `dh.pem`. Does not generate; fails if `make pki` has not been
  run. Fails if `/dev/net/tun` is missing. `chmod o+x DEST` so
  `nobody` can `stat()` the CRL
- `sudo make deploy` — `install-pki`, install the enabled live confs,
  create pool-persist files under `STATE_DIR`, `daemon-reload`,
  `try-restart` those units. Does not install `server.conf`. Does not
  enable units. Does not install nft, sysctl, or systemd drop-ins.
  Fails if `/dev/net/tun` is
  missing

Generate PKI as a normal user, then `sudo make deploy`. Enable the UDP
unit on the host (`systemctl enable --now openvpn-server@server-udp`).
Enable `openvpn-server@server-tcp` only if `ENABLE_TCP=yes`.

`easy-rsa/pki/`, `tc.key`, `client/*.ovpn`, `config.mk`, and the
generated server confs are gitignored.

## Pools

Defaults:

- `tun0` — `10.8.19.0/24` (UDP)
- `tun1` — `10.8.20.0/24` (TCP)

These are not `10.8.0.0/24`. IPv6 is not configured on tun. Clients
`block-ipv6`.
