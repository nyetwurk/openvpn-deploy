# Development

Internals for openvpn-deploy. Operator docs: [README.md](README.md),
[QUICKSTART-VPS.md](QUICKSTART-VPS.md). This file is for changing
templates, `gen-config.py`, or the Makefile.

## Split

- `site.conf` — site knobs. `KEY = value`. No Makefile syntax.
- `gen-config.py` — reads `site.conf`, expands templates, writes
  `server/vars.mk`
- Makefile — PKI, install, units. Includes `server/vars.mk` for
  `PROTOS`, `SERVER_CN`, `REMOTE`, `IPP_FILES`, `CLIENTS`,
  `BOOTSTASH`. Does not `include` `site.conf`

`DEST`, `EASYRSA`, `OPENVPN`, `CERT_DAYS`, and `BOOTSTASH_CLI` stay
Makefile-only. `CLIENTS` and `BOOTSTASH` are site.conf options
(emitted into `server/vars.mk`). Site knobs are not `make VAR=…`.

## Generation

`server/vars.mk` rule is **above** `include` (not `-include`) so a
missing file remakes from a known recipe. `make clean` deletes
`vars.mk`; the next parse remakes it. A missing `site.conf` is
written with `REMOTE` from `hostname -f` and gen-config exits 1 so
Make stops before PKI or confs.

```sh
./gen-config.py init-site
./gen-config.py make-vars [OUT]
./gen-config.py server udp|tcp [OUT]
./gen-config.py nft [OUT]
./gen-config.py client SERVER_CN [CLIENT [CONF [OUT]]]
```

`SITE_CONF` overrides the site file path. Defaults live in
`gen-config.py` (`DEFAULTS`). Unknown keys die. Empty `REMOTE` becomes
`hostname -f`. `example.com` is rejected. `SERVER_CN` defaults to
`REMOTE`. Empty `UDP_IPP` / `TCP_IPP` follow `STATE_DIR`.
`BOOTSTASH` is `auto` or `no` (empty becomes `auto`). After
`clients`, `auto` runs `bootstash put -t .` when the CLI is on
`PATH`, `/usr/sbin`, or `/usr/local/sbin`. Missing CLI or a failed
put does not fail `make`. `BOOTSTASH_CLI` overrides the binary.
`make bootstash` requires a successful put. Do not parse `$DATA`
here.

Templates use `@NAME@`. Unset or leftover names fail. Do not edit
generated files under `server/` or `client/`.

- `server.conf.in` — both UDP and TCP. Optional lines
  (`@PORT_SHARE@`, pushes, `@EXIT_NOTIFY@`) may be blank.
- `client.ovpn.in` — `@SERVER@` `@REMOTE@` `@PORT@` `@PROTO@`
  `@MSSFIX@`. Client writes mode `0600` (create empty, then write).
- `openvpn.nft.in` — WAN-only fragment. Enabled tuns and pools become
  nft sets. Generated `server/openvpn.nft` is `0755` (`#!/usr/sbin/nft
  -f`). Not installed. Do not use on a NAT router that already has
  forward rules.

`mssfix` is on both protos (shared template). It only matters for
`proto udp`. Do not add `fragment` (OpenVPN Connect on Android trips
`FRAG_IN`). `explicit-exit-notify` is UDP only.

## Live confs

Paths are relative to `WorkingDirectory=/etc/openvpn/server`:

- `ca easy-rsa/pki/ca.crt`
- `cert easy-rsa/pki/issued/$(SERVER_CN).crt`
- `key easy-rsa/pki/private/$(SERVER_CN).key`
- `dh none` (ECDHE; no `gen-dh`)
- `tls-crypt tc.key`
- `crl-verify crl.pem`

No `cipher` / `data-ciphers` (OpenVPN 2.6 AES-GCM). No `tls-auth` /
`key-direction`. No `log` / `log-append` / `verb` on the server
(default 1). Client profiles use `verb 3`. Do not set `status` in the
confs (the unit already sets
`/run/openvpn-server/status-%i.log`). Units stay in the foreground;
journald takes stdout.

`crl-verify` is `0644` in `DEST`. `install-pki` does `chmod o+x DEST`
so `nobody` can `stat()` the CRL. `make revoke CLIENT=name` then
`sudo make deploy`.

Pool persist is not under `DEST`: `/var/lib/openvpn-server/ipp.txt`
and `ipp-tcp.txt`. `deploy` creates the dir `0750` `nobody:adm` and
the files `0640` if missing (does not truncate). The process stays
`group nogroup`.

Do not use `openvpn@` (`/etc/openvpn/%i.conf`). Use
`openvpn-server@`.

## Make notes

- `make pki` refuses root. Does not run `gen-dh`. `CERT_DAYS` (3650)
  applies to new certs only. Easy-RSA files come from the Debian
  `easy-rsa` package (`--batch --nopass --days`). This repo does not
  vendor `vars` or `openssl-easyrsa.cnf`.
- `sudo make install-pki` copies CA cert, server cert/key, `tc.key`,
  CRL. Not the CA private key. Fails if `/dev/net/tun` is missing.
- `sudo make deploy` does not install nft, sysctl, or LimitNPROC
  drop-ins. Does not enable units. Does not install the Debian
  `server.conf` sample.
- `server.conf-dist` in the repo is the Debian sample. Not a unit.

Debian `openvpn-server@.service` sets `LimitNPROC`. That can fail in
a VM (`systemd-detect-virt`). Drop-in
`LimitNPROC=infinity` if needed. Skip on the NAT router.

## Firewall notes

`make deploy` must not install nft. A NAT router keeps its existing
firewall; do not install `server/openvpn.nft` there. The generated
`server/openvpn.nft` flushes `inet filter forward` (assumes that chain
is otherwise empty). Do not flush `input`. Do not add `ip filter` /
`ip nat` rules (`nftables.conf` deletes those leftover tables).
SNAT is `table ip openvpn` (delete then define). The fragment does not
punch INPUT; `rfc1918_drop` still matches `10/8` on the host.

`inet filter` forward policy drop means accepts must be in that
chain. Standalone `nft -f` of the fragment needs `inet filter` already
present.

## Gitignore

`easy-rsa/pki/`, `server/`, `client/`, and `site.conf` are gitignored.

## License

Copyright (C) 2026 Nye Liu. Licensed under the GNU GPL version 3 or
later. See [LICENSE](LICENSE).
