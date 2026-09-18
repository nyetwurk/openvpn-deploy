# openvpn-deploy

Deploys OpenVPN for road warriors: stands up a TUN on a Debian VPS and mints
`.ovpn` profiles. This tool installs `openvpn-server@` systemd units and
certificates. Live server endpoint configurations go in `/etc/openvpn/server`.

`openvpn-deploy` is for two Debian environments:

- A WAN-only VPS with no LAN (you must forward and masquerade the
  VPN subnet yourself; this tool can emit a Debian nftables snippet.
  `make deploy` does not install firewall or sysctl files. See
  [QUICKSTART-VPS.md](QUICKSTART-VPS.md).
- An existing NAT router that already masquerades a LAN (keep that host’s
  existing firewall)

UDP is the recommended tunnel. TCP on 443 is an optional fallback when UDP is
blocked. OpenVPN server listeners can share that port with a local HTTPS daemon
by listening on 443 and forwarding non-OpenVPN traffic to that daemon on a
different port.

Clients get a full tunnel by default, an optional LAN route and optional DNS
pushed to them, and a symmetric, shared `tls-crypt` key. Client IPv6 is blocked.

## Configuration

Run `make` to create an initial site configuration if one does not exist yet.
The first `make` writes `site.conf` with `REMOTE` from `hostname -f` and stops.

Edit `site.conf` to your needs.

The initial auto-generated `site.conf` will contain `REMOTE` from `hostname -f`
and nothing else. Add only the options you need from `examples/site.conf`. Do
not copy that catalog over `site.conf` (every line there is commented; you
would lose `REMOTE`).

Run `make` again to create OpenVPN server configuration(s) and client profile(s)
from `site.conf`. If `CLIENTS` is not set, it will default to creating profiles
for your current login name.

`REMOTE=example.com` is rejected (that placeholder is not a real remote).
Omitting `REMOTE` uses `hostname -f`.

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

Each `.ovpn` contains that client’s private key (`0600`). One profile per
device. Do not run the UDP and TCP profiles at the same time on the same
device.

Generally, only use TCP if UDP is blocked.

Copy `client/*.ovpn` off the OpenVPN host to the client device(s). (e.g. `scp`
to a laptop, USB, AirDrop, Nearby Share). Do not share the profile as “anyone
with the link”, it contains sensitive keys. Avoid email if possible unless you
are using a secure email service or PGP/GPG encrypted email.

Import the profile to **OpenVPN Connect**. On mobile devices the import action
is sometimes mislabeled **Upload**.

[bootstash](https://github.com/nyetwurk/bootstash) is another way to transfer
the profile to the client device. It is an HTTP/HTTPS cubby that combines
Google OIDC with PAM. Once authenticated, the client can download the profile
in a browser.

If bootstash is on this host, `cp` into
`/var/lib/bootstash/users/<linux-username>/`; `scp` when it is not.
The client must reach that host *before* the tunnel is up. This
Makefile does not install it. `PORT_SHARE` is for a local HTTPS daemon, not
`.ovpn` files.

## Firewall/Routing

A LAN host that dials the WAN address hits this machine directly (no
hairpin). With `LAN_ROUTE` set, other LAN destinations go through the
tunnel.

`make deploy` does not install firewall rules. Clients need this
policy on the OpenVPN host (any backend):

- `net.ipv4.ip_forward=1`
- Forward established connections from the WAN back to the TUN
- Forward the VPN subnet out the WAN
- Masquerade the VPN subnet out the WAN

A WAN-only VPS usually has no existing LAN masquerade. Implement the policy in
whatever you run (nftables, iptables, ufw, firewalld). If you are using Debian
and nftables, also see [QUICKSTART-VPS.md](QUICKSTART-VPS.md).

An existing NAT router that already masquerades a LAN usually has forwarding and
subnet masquerading already configured via `sysctl` and `iptables/nftables`
respectively. You will only need to add the TUN subnet as if it were just
another LAN subnet.

> [!WARNING]
> `server/openvpn.nft` flushes `inet filter forward`. Do not install
> it on a host that already has other forward rules. Do not load it
> next to iptables-nft `ip filter` / `ip nat` on a Debian host whose
> `nftables.conf` deletes those tables.

`iptables`, `ipfw`, and other emitters are not included. They may be added
later.

If the unit fails to start in a VM or container, add a systemd
drop-in with `[Service]` / `LimitNPROC=infinity`. `make deploy` will not
install one for you.

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
