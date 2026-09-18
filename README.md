# openvpn-deploy

Simple OpenVPN for road warriors: stand up a TUN on a Debian VPS and
get client profiles to take on the road. It installs
`openvpn-server@` systemd units, certificates, and `.ovpn` profiles
you import in OpenVPN Connect (in Android, *Import* is misnamed
**Upload**). Files go in `/etc/openvpn/server`.

It is for two Debian environments:

- A WAN-only VPS with no LAN (you must forward and masquerade the
  VPN subnet yourself; this tool can emit a Debian nftables snippet.
  `make deploy` does not install firewall or sysctl files)
- An existing NAT router that already masquerades a LAN (keep that host’s
  existing firewall)

UDP is the recommended tunnel. TCP on 443 is an optional fallback when UDP
is blocked, and can share that port with a local HTTPS daemon.
Clients get a full tunnel by default, an optional LAN route and DNS,
and a `tls-crypt` key. Client IPv6 is blocked.

Command sequence, packages, and Debian nftables:
[QUICKSTART-VPS.md](QUICKSTART-VPS.md). On a NAT router skip the
nftables and sysctl steps; `make`, edit `site.conf`, `make`,
`sudo make deploy`.

## Configuration

The first `make` creates `site.conf` with `REMOTE` from
`hostname -f` and stops. Add only the options you need from
`examples/site.conf`. Do not copy that catalog over `site.conf`.
`REMOTE=example.com` is rejected.

| Variable | Role |
| --- | --- |
| `REMOTE` | Hostname clients dial; defaults to `hostname -f`. Also the server certificate name unless `SERVER_CN` is set |
| `SERVER_CN` | Optional server certificate name; defaults to `REMOTE` |
| `ENABLE_UDP` / `ENABLE_TCP` | `yes` to build and restart that listener (TCP defaults to `no`) |
| `UDP_PORT` / `TCP_PORT` | Listen ports (`1194` / `443`) |
| `UDP_DEV` / `TCP_DEV` | TUN devices (`tun0` / `tun1`) |
| `UDP_POOL` / `TCP_POOL` | VPN address ranges. Defaults: `10.8.19.0/24` UDP, `10.8.20.0/24` TCP |
| `LAN_ROUTE` / `DNS` | LAN route and DNS pushed to clients; omit to skip. `DNS` also blocks Windows from using other resolvers |
| `REDIRECT_GATEWAY` | Full tunnel (the default). Set empty for split tunnel (`LAN_ROUTE` only) |
| `PORT_SHARE` | TCP only: send non-OpenVPN traffic on 443 to a local HTTPS daemon. That daemon must not listen on `TCP_PORT` itself |
| `WAN_IF` | WAN interface name for the optional nftables snippet (`eth0`) |
| `CLIENTS` | Who gets a profile. Space-separated names. Defaults to your login |

> [!CAUTION]
> A wrong `LAN_ROUTE` can steal a client's home or office subnet so
> those addresses go through the VPN instead of their LAN.

If you change `SERVER_CN` (or `REMOTE`, when `SERVER_CN` is unset)
after the first `make`, issue a new server certificate. Turning a
listener off in `site.conf` does not stop a unit you already enabled.

Do not edit files under `server/` or `client/` by hand; run `make`
again.

## Clients

Each `.ovpn` contains that device’s private key (`0600`). Import one
profile per device. Do not run the UDP and TCP profiles at the same
time. Use UDP unless UDP is blocked.

A LAN host that dials the WAN address hits this machine directly (no
hairpin). With `LAN_ROUTE` set, other LAN destinations go through the
tunnel.

## Firewall

`make deploy` does not install firewall rules. Clients need this
policy on the OpenVPN host (any backend):

- `net.ipv4.ip_forward=1`
- Forward established connections from the WAN back to the TUN
- Forward the VPN subnet out the WAN
- Masquerade the VPN subnet out the WAN

A NAT router that already masquerades a LAN usually has the first
and last already. Still allow the TUN path if you change `UDP_DEV` /
`TCP_DEV` or the pools.

A WAN-only VPS has no LAN masquerade. Implement the policy in
whatever you run (nftables, iptables, ufw, firewalld). Debian
nftables: [QUICKSTART-VPS.md](QUICKSTART-VPS.md).

> [!WARNING]
> `server/openvpn.nft` flushes `inet filter forward`. Do not install
> it on a host that already has other forward rules. Do not load it
> next to iptables-nft `ip filter` / `ip nat` on a Debian host whose
> `nftables.conf` deletes those tables.

iptables (and other) emitters are not included. They may be added
later.

If the unit fails to start in a VM or container, add a systemd
drop-in with `[Service]` / `LimitNPROC=infinity`. `make deploy`
does not install it.

## Commands

Run `make` as a normal user, then `sudo make deploy`.

- `make` — server configs, certificates, and profiles for `CLIENTS`
- `make clients` — `client/name.ovpn` and/or `client/name.tcp.ovpn`
- `sudo make deploy` — install configs and certificates, create
  address-assignment files, restart the enabled units. Does not
  enable units. Does not install firewall or sysctl files

> [!WARNING]
> Overwrites files under `/etc/openvpn/server` (including the CA
> cert, server cert/key, and `tc.key`) and can break OpenVPN
> services this tool does not manage.

- `make revoke CLIENT=name` — revoke that client, then
  `sudo make deploy`
- `make dryrun` — compare generated configs to what is installed
- `make clean` — generated configs and `client/` (keeps certificates)
- `make distclean` — `clean` plus all certificates. Does not delete
  `site.conf`

> [!WARNING]
> `make distclean` deletes the CA, every issued certificate, and
> `server/tc.key`. There is no undo.

Logs: `journalctl -u openvpn-server@server-udp`. Connected clients:
`sudo cat /run/openvpn-server/status-server-udp.log`. Assigned VPN
addresses persist in `/var/lib/openvpn-server/` (`ipp.txt` /
`ipp-tcp.txt`).

If `PORT_SHARE` is on, leftover HTTPS accepts on 443 appear in the
log. That is not a VPN client.

## License

Copyright (C) 2026 Nye Liu. Licensed under the GNU GPL version 3 or
later. See [LICENSE](LICENSE).
