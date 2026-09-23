# openvpn-deploy

Deploys OpenVPN for road warriors: stands up a TUN on a Debian VPS and mints
`.ovpn` profiles. `make` writes `openvpn-server@` configs and certificates;
`sudo make deploy` copies them to `/etc/openvpn/server`. Enable the units
yourself.

`openvpn-deploy` is for two Debian environments:

- A WAN-only VPS with no LAN (you must forward and masquerade the
  VPN subnet yourself; this tool can emit a Debian nftables snippet.
  `make deploy` copies that snippet when `NFT_DEST` is set
  (`NFT_MODE` defaults to `vps`), and it does not install sysctl. See
  [QUICKSTART-VPS.md](QUICKSTART-VPS.md).
- An existing NAT router that already masquerades a LAN (keep that host’s
  existing firewall)

UDP is the recommended tunnel. TCP on 443 is an optional fallback when UDP is
blocked. That public TCP port can be OpenVPN alone, OpenVPN muxing HTTPS
(`PORT_SHARE`), or another mux with OpenVPN on a private socket (`TCP_LISTEN`).

Clients get a full tunnel by default, an optional LAN route and optional DNS
pushed to them, and a symmetric, shared `tls-crypt` key. The tun is dual-stack
by default (a `/112` from the WAN GUA, NAT66). `ENABLE_IPV6=no` blocks client
IPv6.

## Configuration

The first `make` writes `site.conf` with `REMOTE` from `hostname -f` and
stops. Add only the options you need from `examples/site.conf`. Do not
copy that catalog over `site.conf` (every line there is commented; you
would lose `REMOTE`). Then `make` again. Empty `CLIENTS` defaults to
your login. `REMOTE=example.com` is rejected. Omitting `REMOTE` uses
`hostname -f`.

| Variable | Role |
| --- | --- |
| `REMOTE` | Hostname clients dial; defaults to `hostname -f`. Also the server certificate name unless `SERVER_CN` is set |
| `SERVER_CN` | Optional server certificate name; defaults to `REMOTE` |
| `ENABLE_UDP` / `ENABLE_TCP` | `yes` to build and restart that listener (TCP defaults to `no`) |
| `UDP_PORT` / `TCP_PORT` | Ports clients dial (`1194` / `443`). TCP listen port unless `TCP_LISTEN` is set |
| `UDP_DEV` / `TCP_DEV` | TUN devices (`tun0` / `tun1`) |
| `UDP_POOL` / `TCP_POOL` | VPN address ranges (`address netmask`). Defaults: `10.8.19.0 255.255.255.0` UDP, `10.8.20.0 255.255.255.0` TCP |
| `ENABLE_IPV6` | Dual-stack on the tun (`/112`, NAT66). Default `yes`. `no` writes `block-ipv6` in the profile. The listener stays IPv4 (`proto udp` / `tcp`) |
| `UDP_POOL6` / `TCP_POOL6` | IPv6 VPN prefixes when `ENABLE_IPV6=yes` (CIDR `/112`). Empty (the default) carves a `/112` from the GUA on `WAN_IF`. Set to override (ULA or another GUA) |
| `LAN_ROUTE` / `DNS` | LAN route and DNS pushed to clients; omit to skip. `DNS` also blocks Windows from using other resolvers |
| `REDIRECT_GATEWAY` | Full tunnel (the default). Set empty for split tunnel (`LAN_ROUTE` only) |
| `PORT_SHARE` | TCP only: OpenVPN muxes `TCP_PORT` toward this HTTPS daemon (`address port`). That daemon must not listen on `TCP_PORT`. Mutually exclusive with `TCP_LISTEN` |
| `TCP_LISTEN` | TCP only: OpenVPN listens here (`address port`) when another mux owns `TCP_PORT`. Clients still dial `TCP_PORT`. Mutually exclusive with `PORT_SHARE` |
| `WAN_IF` | WAN interface (`eth0`). nft snippet and the GUA that empty `UDP_POOL6` / `TCP_POOL6` carve from |
| `CLIENTS` | Who gets a profile. Space-separated names. Defaults to your login |
| `DUPLICATE_CN` | `yes` allows several live sessions with the same client cert (shared `.ovpn`) and omits pool persist. Default `no` |
| `BOOTSTASH` | `auto` (default): after `make` / `make clients`, `bootstash put` if the CLI is present. `no` skips |

> [!CAUTION]
> A wrong `LAN_ROUTE` can steal a client's home or office subnet so
> those addresses go through the VPN instead of their LAN.

If you change `SERVER_CN` (or `REMOTE`, when `SERVER_CN` is unset)
after the first `make`, issue a new server certificate. Turning a
listener off in `site.conf` does not stop a unit you already enabled.

Do not edit files under `server/` or `client/` by hand; run `make`
again.

## Clients

Each `.ovpn` contains that client’s private key (`0600`). By default
OpenVPN allows one live session per certificate. Prefer one name in
`CLIENTS` per device. `DUPLICATE_CN=yes` lets several devices share
one profile at once; revoke then hits all of them. Do not run the UDP
and TCP profiles at the same time on the same device.

Generally, only use TCP if UDP is blocked.

Copy `client/*.ovpn` off the OpenVPN host (scp, USB, AirDrop, Nearby
Share). Do not share the profile as “anyone with the link.” It
contains sensitive keys. Avoid email unless it is encrypted.

Import the profile in **OpenVPN Connect**. On mobile the action is
sometimes labeled **Upload**; that means import.

[bootstash](https://github.com/nyetwurk/bootstash) is optional (Google
OIDC + PAM in a browser). `BOOTSTASH=auto` puts into the local cubby
when the CLI is present; the cubby exists after a PAM link. `scp` if
the cubby is elsewhere. The phone must reach that host *before* the
tunnel is up. This Makefile does not install the package. `PORT_SHARE` and
`TCP_LISTEN` are not a profile server.

## Firewall/Routing

A LAN host that dials the WAN address hits this machine directly (no
hairpin). With `LAN_ROUTE` set, other LAN destinations go through the
tunnel.

`make deploy` does not install sysctl. It copies an nft fragment
when `NFT_DEST` is set. `NFT_MODE` defaults to `vps`
(`server/openvpn.nft`; `nat` → `server/openvpn-nat.nft`), and it
does not `nft -f`. `make dryrun` diffs `NFT_DEST` against that
file. Empty `NFT_DEST` skips the copy.
Clients need this policy on the OpenVPN host (any backend):

- `net.ipv4.ip_forward=1`
- `net.ipv6.conf.all.forwarding=1` unless `ENABLE_IPV6=no`
- `net.ipv6.conf.all.accept_ra=2` (and `default`) if the WAN IPv6
  default is RA; `forwarding=1` otherwise ignores RAs
- Forward established connections from the WAN back to the TUN
- Forward the VPN subnet out the WAN
- Masquerade the VPN IPv4 subnet out the WAN. Unless `ENABLE_IPV6=no`,
  SNAT the tun `/112` to the WAN GUA (nft masquerade can pick a
  deprecated address)

A WAN-only VPS usually has no existing LAN masquerade. Implement the policy in
whatever you run (nftables, iptables, ufw, firewalld). If you are using Debian
and nftables, also see [QUICKSTART-VPS.md](QUICKSTART-VPS.md).
If input drops RFC1918, limit that to the WAN (`iifname` the WAN). A
global `@rfc1918_drop` also matches the VPN pool, so clients cannot
reach this host. Same for a global ULA drop if the tun pool is ULA.

An existing NAT router that already masquerades a LAN usually has forwarding and
IPv4 SNAT already configured. Add the IPv4 TUN subnet the same way as the LAN.
The tun IPv6 `/112` is carved from the **WAN** GUA (on-link), not the LAN PD,
so it is not “another LAN prefix”: ip6 **FORWARD** must accept `$VPN_IF`, and
postrouting must **SNAT** that `/112` to the stable WAN GUA (nft masquerade
can pick a deprecated SLAAC address). Do not install `server/openvpn.nft`
on that host (it flushes `inet filter forward`). An accept in a second
table does not override `policy drop` on the existing forward chain.

`make` also writes `server/openvpn-nat.nft` from
[`openvpn-nat.nft.in`](openvpn-nat.nft.in). Set `NFT_MODE=nat` and
`NFT_DEST` to an absolute path that loads after the filter and nat
tables (for example `/etc/nftables.d/50-openvpn.nft`) so
`sudo make deploy` copies it there. With `NFT_DEST` empty, copy the
file yourself. The parent keeps its own chains and jumps into empty
`openvpn` / `openvpn_dnat` / `openvpn_snat` chains; the fragment
only flushes those. It does not flush forward. It defines the tun
sets from `site.conf` and uses the parent's `WAN_*` and `LAN_*`
addresses. DNS intercept to the LAN resolver is in that file.

Dual-stack (the default) needs a public IPv6 on `WAN_IF`. Empty
`UDP_POOL6` / `TCP_POOL6` take a `/112` from that GUA and SNAT it
to that GUA (not a routed `/64`, not nft masquerade). Set
`ENABLE_IPV6=no` if the WAN is IPv4-only. An explicit ULA pool still
loses to IPv4 (RFC 6724).

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

Optional fail2ban: Debian's package has no OpenVPN filter.
`sudo make deploy` copies [`examples/fail2ban/`](examples/fail2ban/)
when `/etc/fail2ban` exists. Three tls-crypt unwrap, TLS handshake
failure, or `VERIFY ERROR` hits in 2h ban for 4h (garbage on the
listen port, or a stale/revoked `.ovpn`). The ban is all UDP and
TCP, not `UDP_PORT` / `TCP_PORT`. Skips if the package is not
installed. Does not `apt install` fail2ban. Reload happens only if
the service is already running.

## Commands

Run `make` as a normal user, then `sudo make deploy`.

- `make` — server configs, certificates, and profiles for `CLIENTS`
- `make clients` — `client/name.ovpn` and/or `client/name.tcp.ovpn`
  (both also `bootstash put` when `BOOTSTASH=auto` and the CLI is present)
- `make bootstash` — `bootstash put` only (fails if the CLI is missing)
- `sudo make deploy` — install configs and certificates, create
  address-assignment files, restart the enabled units. Copies the
  fail2ban tls-crypt jail if `/etc/fail2ban` exists. Does not
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
`ipp-tcp.txt`) unless `DUPLICATE_CN=yes`.

If `PORT_SHARE` is on, leftover HTTPS accepts on 443 appear in the
OpenVPN log. That is not a VPN client. `TCP_LISTEN` does not do that;
HTTPS never reaches OpenVPN.

## Sharing TCP 443

Omit both knobs: OpenVPN listens on `TCP_PORT` (443) alone.

`PORT_SHARE = 127.0.0.1 8443`: OpenVPN is the mux. It listens on 443 and
forwards non-OpenVPN TCP to that HTTPS daemon. Apache sees `127.0.0.1`.
The daemon must not listen on 443.

`TCP_LISTEN = 127.0.0.1 1194`: another process owns 443. OpenVPN TCP binds
that socket. `.tcp.ovpn` still dials `TCP_PORT` (443). This Makefile
does not install that process.

Debian HAProxy can mux 443: TLS to Apache with PROXY v2, everything else
to OpenVPN. Copy [`examples/haproxy-local.cfg`](examples/haproxy-local.cfg)
to `/etc/haproxy/haproxy-local.cfg`. Keep `CONFIG` on the stock
`/etc/haproxy/haproxy.cfg` and in `/etc/default/haproxy` set:

```
EXTRAOPTS="-S /run/haproxy-master.sock -f /etc/haproxy/haproxy-local.cfg"
```

That is `-f haproxy.cfg -f haproxy-local.cfg`. Do not set `CONFIG` to
the local file alone (no `global`/`defaults` from stock). Apache must
listen only on loopback and enable `mod_remoteip`, or anyone who can
reach 8443 can spoof client IPs: `Listen 127.0.0.1:8443`,
`a2enmod remoteip`, `RemoteIPProxyProtocol On`. Cutover: stop
`openvpn-server@server-tcp`, `sudo make deploy` with `TCP_LISTEN`,
start HAProxy.

## License

Copyright (C) 2026 Nye Liu. Licensed under the GNU GPL version 3 or
later. See [LICENSE](LICENSE).
