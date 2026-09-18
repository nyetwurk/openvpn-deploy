# WAN-only VPS quickstart

This guide is for a Debian VPS with no LAN. It is not for a NAT router
that already masquerades a LAN.

What the tool is, `site.conf` options, and Make targets:
[README.md](README.md).

```sh
sudo apt install make python3 easy-rsa openvpn nftables
```

Debian's stock `/etc/nftables.conf` does not include
`/etc/nftables.d/`. The OpenVPN fragment expects `inet filter` to
already exist, and boot-time load needs this include. If
`/etc/nftables.conf` already has `include "/etc/nftables.d/*.nft"`,
skip the copy.

If `/etc/nftables.conf` already has host rules (not just an include),
move those rules into a snippet under `/etc/nftables.d/` (for example
`/etc/nftables.d/10-host.nft`) and replace `/etc/nftables.conf` with
`examples/nftables.conf`. Leaving rules only in the old
`nftables.conf` drops them on the next `nftables.service` load.

```sh
sudo mkdir -p /etc/nftables.d
sudo cp examples/nftables.conf /etc/nftables.conf
sudo systemctl enable --now nftables
```

`examples/nftables.conf` is:

```nft
#!/usr/sbin/nft -f

# Minimal WAN-only host. Defines inet filter so snippets under
# /etc/nftables.d/ can flush and add forward rules. Copy to
# /etc/nftables.conf only if that file does not already include
# "/etc/nftables.d/*.nft". If the current nftables.conf has host
# rules, move them into /etc/nftables.d/ first (e.g. 10-host.nft).
# Do not use on a NAT router that already has forward/NAT rules.
# Include is an absolute path so `nft -f /etc/nftables.conf` works
# from any cwd. The glob is not recursive.

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter;
	}
	chain forward {
		type filter hook forward priority filter;
		policy drop;
	}
	chain output {
		type filter hook output priority filter;
	}
}

include "/etc/nftables.d/*.nft"
```

> [!WARNING]
> Replacing `/etc/nftables.conf` without first moving existing rules
> into `/etc/nftables.d/` drops those rules on the next
> `nftables.service` load.

```sh
make
```

If `site.conf` is missing, it is created with `REMOTE` from
`hostname -f` and `make` stops. Edit `site.conf` (set `WAN_IF` if the
WAN is not `eth0`). Copy individual options from `examples/site.conf`.
Do not `cp examples/site.conf site.conf`. Options:
[README.md](README.md#configuration).

```sh
make
sudo cp examples/99-openvpn-forward.conf /etc/sysctl.d/
sudo sysctl -p /etc/sysctl.d/99-openvpn-forward.conf
sudo cp server/openvpn.nft /etc/nftables.d/openvpn.nft
sudo /etc/nftables.d/openvpn.nft
sudo make deploy
sudo systemctl enable --now openvpn-server@server-udp
```

Enable `openvpn-server@server-tcp` only if `ENABLE_TCP=yes`.

> [!WARNING]
> `server/openvpn.nft` flushes `inet filter forward`. Deploy writes
> `/etc/openvpn/server` and can break other OpenVPN units that share
> that directory or those unit names.

Import `client/*.ovpn` in OpenVPN Connect. On Android the file action
is labeled **Upload**; that means import the profile onto the phone,
not send it to a server.
