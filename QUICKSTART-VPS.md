# WAN-only VPS quickstart

This guide is for a Debian VPS with no LAN. It is not for a NAT router
that already masquerades a LAN.

## Install required packages

```sh
sudo apt install make python3 easy-rsa openvpn nftables
```

## Create `site.conf`

```sh
make
```

- Edit `site.conf` to your needs.
- Set `WAN_IF` if the WAN is not `eth0`.

See [`examples/site.conf`](examples/site.conf) and
[README.md#configuration](README.md#configuration) for the full list of
available options.

## Configure nftables

Debian's stock `/etc/nftables.conf` does not include
`/etc/nftables.d/`. The OpenVPN fragment expects `inet filter` to
already exist, and boot-time load needs this include. If
`/etc/nftables.conf` already has `include "/etc/nftables.d/*.nft"`,
skip the copy.

If `/etc/nftables.conf` already has host rules (not just an include),
move those rules into a snippet under `/etc/nftables.d/` (for example
`/etc/nftables.d/10-host.nft`) and replace `/etc/nftables.conf` with
[`examples/nftables.conf`](examples/nftables.conf).

Leaving rules only in the old `nftables.conf` drops them on the next
`nftables.service` load.

```sh
sudo mkdir -p /etc/nftables.d
sudo cp examples/nftables.conf /etc/nftables.conf
sudo systemctl enable --now nftables
```

> [!WARNING]
> Replacing `/etc/nftables.conf` without first moving existing rules
> into `/etc/nftables.d/` drops those rules on the next
> `nftables.service` load.

## Build server confs, certificates, profiles, and OpenVPN nft fragment

The next `make` builds server confs, certificates,
profiles, and `server/openvpn.nft`.

```sh
make
```

## Install sysctl and nft fragments

```sh
sudo cp examples/99-openvpn-forward.conf /etc/sysctl.d/
sudo sysctl -p /etc/sysctl.d/99-openvpn-forward.conf
sudo cp server/openvpn.nft /etc/nftables.d/openvpn.nft
sudo /etc/nftables.d/openvpn.nft
```

## Install server configs/units and start OpenVPN

```sh
sudo make deploy
sudo systemctl enable --now openvpn-server@server-udp
sudo systemctl enable --now openvpn-server@server-tcp
```

Enable `openvpn-server@server-tcp` only if `ENABLE_TCP=yes`.

> [!WARNING]
> `server/openvpn.nft` flushes `inet filter forward`. Deploy writes
> `/etc/openvpn/server` and can break other OpenVPN units that share
> that directory or those unit names.

`scp` `client/*.ovpn` off this VPS, or `cp` into local
[bootstash](https://github.com/nyetwurk/bootstash) /
`scp` to a remote one. Profiles:
[README.md#clients](README.md#clients).
