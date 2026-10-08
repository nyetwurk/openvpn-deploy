# WAN-only VPS quickstart

This guide is for a Debian VPS with no LAN. It is not for a NAT router
that already masquerades a LAN.

The throwaway boot builds a stock Debian image from `vps.yaml`. The
PKI is created on that machine. The later sections are a hand install
on a VPS you already have.

## Throwaway boot

Copy [`examples/vps.yaml`](examples/vps.yaml) to `vps.yaml` and fill it
in. A launch script rebuilds `launch/cloud-init.yaml` and creates the
machine.

- `launch/create-vm-do.sh`, `launch/create-vm-gce.sh`, or `launch/create-vm-aws.sh` for a public VPS. `launch/create-vm-local.sh` boots a guest on this host and stops before a certificate.
- Full tunnel, UDP only. Dual-stack when the WAN has a global IPv6; otherwise v4-only.
- The client's resolver is bind on the tunnel address. The client's ISP does not see those queries. Authoritative servers see the VPS address. A client that ignores the push still queries its previous resolver, through the tunnel. Set `DNS` in `vps.yaml` to push a different resolver and skip bind.
- Login is PAM at `https://REMOTE`: the image user, and a password the launch script asks for. `PROVISION: google` sends a client JSON instead. Profiles go in that user's cubby.

Boot internals: [DEVELOPMENT.md](DEVELOPMENT.md).

## Install required packages

```sh
sudo apt install make python3 easy-rsa openvpn nftables
```

## Create `site.conf`

```sh
make
```

That writes `site.conf` with `REMOTE` from `hostname -f` and stops.

- Edit `site.conf` to your needs.
- Set `WAN_IF` if the WAN is not `eth0`.
- Omitted `ENABLE_IPV6` follows that WAN. A global IPv6 means
  dual-stack (NAT66, not a routed `/64`); empty pools take a `/112`
  from that GUA. No global IPv6 means v4-only. Set `yes` or `no` to
  override. The sysctl
  example sets `accept_ra=2` so `forwarding=1` does not drop a
  SLAAC WAN default.

See [`examples/site.conf`](examples/site.conf) and
[README.md#configuration](README.md#configuration) for the full list of
available options.

## Configure nftables

Debian's stock `/etc/nftables.conf` is a live ruleset (an uncommented
`inet filter` table). It does not include `/etc/nftables.d/`. The
OpenVPN fragment expects `inet filter` to already exist, and
boot-time load needs this include. `vps/provision.sh` leaves that
file in place and appends `include "/etc/nftables.d/*.nft"` when the
line is missing. If the include is already there, skip the copy.

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

The next `make` builds server confs, certificates, profiles, and
`server/openvpn.nft`. `BOOTSTASH=auto` (the default) also runs
`sudo -n bootstash mkdir` for the current user, then `bootstash put`,
when the CLI is on this host.

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

Skip the `openvpn.nft` copy when `site.conf` sets
`NFT_DEST=/etc/nftables.d/openvpn.nft`. `NFT_MODE` defaults to
`vps`. `sudo make deploy` copies
that file and does not load it. Run `nft -f /etc/nftables.conf` (or
the fragment) yourself. `make dryrun` diffs `NFT_DEST` against
`server/openvpn.nft`. Sysctl stays a manual copy.

## Install server configs/units and start OpenVPN

```sh
sudo make deploy
sudo systemctl enable --now openvpn-server@server-udp
```

Enable `openvpn-server@server-tcp` only if `ENABLE_TCP=yes`.

> [!WARNING]
> `server/openvpn.nft` flushes `inet filter forward`. A NAT router
> sets `NFT_MODE=nat` and `NFT_DEST`, or copies `server/openvpn-nat.nft`.
> Deploy writes `/etc/openvpn/server` and can break other OpenVPN
> units that share that directory or those unit names.

`scp` `client/*.ovpn` off this VPS if you did not use local
[bootstash](https://git.nyet.org/bootstash). Profiles:
[README.md#clients](README.md#clients).

## Optional fail2ban

Debian fail2ban has no OpenVPN filter. Install the package so
`sudo make deploy` can copy the jail. Deploy skips this if
`/etc/fail2ban` is missing. Three tls-crypt unwrap, TLS handshake
failure, or `VERIFY ERROR` hits in 2h ban. A stale or revoked
`.ovpn` logs the same lines as a probe.

```sh
sudo apt install fail2ban
sudo make deploy
```

Put your own addresses in `ignoreip` (another jail.d file, not the
copied jail). The ban is all UDP and TCP ports, not `UDP_PORT` /
`TCP_PORT`.
