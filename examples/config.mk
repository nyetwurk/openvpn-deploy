# Site overrides. Copy to config.mk at the repo root and uncomment
# only what you change.
#   cp examples/config.mk config.mk
#
# Defaults live in the Makefile. Repo-root config.mk is gitignored. Command-line
# make VAR=... still overrides (do not use `override` here).
#
# Changing SERVER_CN after `make pki` needs a new server cert (pki-clean
# or remove that issued cert). Changing tun/pools on the NAT router
# needs the sibling nftables tree (../nftables). A WAN-only host uses
# examples/50-openvpn.nft instead (not installed by make deploy).

# Certificate CN, `remote`, and `verify-x509-name` unless REMOTE is set.
# SERVER_CN = example.com

# Hostname clients dial. Defaults to SERVER_CN when omitted.
# REMOTE = vpn.example.com

# Listeners. Anything other than `yes` skips that unit, its conf, and
# its client profiles. Stop leftover units on the host yourself.
# ENABLE_UDP = yes
# ENABLE_TCP = no

# UDP_PORT = 1194
# TCP_PORT = 443
# UDP_DEV = tun0
# TCP_DEV = tun1

# OpenVPN `server` / `push route` form: address then netmask.
# UDP_POOL = 10.8.19.0 255.255.255.0
# TCP_POOL = 10.8.20.0 255.255.255.0
# Empty = do not push. Wrong LAN_ROUTE can steal a client's local subnet.
# LAN_ROUTE = 192.168.1.0 255.255.255.0
# Empty = clients keep their resolver. Full tunnel still works.
# DNS = 192.168.1.1

# UDP_IPP = /var/log/openvpn/ipp.txt
# TCP_IPP = /var/log/openvpn/ipp-tcp.txt

# CIPHER = AES-256-CBC
# MSSFIX = 1360

# Full-tunnel push. Empty = split tunnel (LAN_ROUTE only).
# REDIRECT_GATEWAY = redirect-gateway def1 bypass-dhcp

# TCP only: non-OpenVPN traffic on TCP_PORT. Empty = off.
# Apache must not Listen on TCP_PORT when this is set.
# PORT_SHARE = 127.0.0.1 8443

# DEST = /etc/openvpn/server
# CLIENTS = alice bob
# OPENVPN = /usr/sbin/openvpn
