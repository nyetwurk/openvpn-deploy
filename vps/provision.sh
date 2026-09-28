#!/bin/bash
# Unattended remote boot. Stops before bootstash is started.
# The local script pipes the Google client JSON and starts the unit.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_user
load_env
require_remote
: "${BOOTSTASH_DEB_URL:?}" "${ACME_EMAIL:?}"
[[ -e /dev/net/tun ]] || die "TUN device missing; enable /dev/net/tun"

echo "vps: ssl-cert group for bootstash.service"
sudo_do apt-get install -y ssl-cert

echo "vps: fetching $BOOTSTASH_DEB_URL"
deb=$(mktemp)
curl -fL --retry 3 -o "$deb" "$BOOTSTASH_DEB_URL"
if [[ -n "${BOOTSTASH_DEB_SHA256:-}" ]]; then
	echo "$BOOTSTASH_DEB_SHA256  $deb" | sha256sum -c -
fi
sudo_do dpkg -i "$deb" || sudo_do apt-get -f install -y
rm -f "$deb"
dpkg -s bootstash >/dev/null 2>&1 || die "bootstash package is not installed"

if [[ -f /etc/openvpn-deploy.site.conf && ! -f site.conf ]]; then
	cp /etc/openvpn-deploy.site.conf site.conf
fi
[[ -f site.conf ]] || die "site.conf missing"
tmp=$(mktemp)
if [[ -f /etc/default/bootstash ]]; then
	awk -F= '
		$1 != "LISTEN" && $1 != "PUBLIC_URL" && $1 != "CERT_NAME" && \
		$1 != "ALLOWED_EMAILS" && $1 != "REQUIRE_PAM_LINK" { print }
	' /etc/default/bootstash >"$tmp"
fi
{
	printf 'LISTEN=%s\n' '*:443'
	printf 'PUBLIC_URL=https://%s\n' "$REMOTE"
	printf 'CERT_NAME=%s\n' "$REMOTE"
} >>"$tmp"
sudo_do install -m 644 "$tmp" /etc/default/bootstash
rm -f "$tmp"
echo "vps: bootstash LISTEN=*:443 PUBLIC_URL=https://$REMOTE CERT_NAME=$REMOTE"

wan=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$wan" ]] || die "no default IPv4 route"
ip4=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')
[[ -n "$ip4" ]] || die "no IPv4 on the default route"
echo "vps: default route $wan source $ip4"
if ! grep -Eq '^[[:space:]]*WAN_IF[[:space:]]*=' site.conf; then
	printf '\nWAN_IF = %s\n' "$wan" >>site.conf
	echo "vps: wrote WAN_IF=$wan"
fi

site_get() {
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" site.conf | head -1
}

# First host of the v4 pool, then the prefix. OpenVPN topology subnet
# takes that host as the server address.
pool_v4() {
	python3 - "$@" <<'PY'
import ipaddress, sys
words = sys.argv[1].split()
if len(words) == 1:
    net = ipaddress.ip_network(words[0], strict=False)
else:
    net = ipaddress.ip_network(f"{words[0]}/{words[1]}", strict=False)
print(net.network_address + 1)
print(net)
PY
}

write_named_options() {
	local addr=$1 net=$2 ip6=${3:-} net6=${4:-}
	local v6_listen="none;" acls="127.0.0.1; ${net};"
	if [[ -n "$ip6" ]]; then
		v6_listen="${ip6};"
		acls="${acls} ${net6};"
	fi
	sudo_do tee /etc/bind/named.conf.options >/dev/null <<EOF
options {
	directory "/var/cache/bind";
	recursion yes;
	dnssec-validation auto;
	interface-interval 10;
	listen-on { 127.0.0.1; ${addr}; };
	listen-on-v6 { ${v6_listen} };
	allow-query { ${acls} };
	allow-recursion { ${acls} };
};
EOF
	sudo_do chmod 644 /etc/bind/named.conf.options
}

# Global IPv6 addresses on dev, one per line. With a second argument,
# wait until that address is present.
wait_tun6() {
	local dev=$1 want=${2:-} i seen
	for i in 1 2 3 4 5 6 7 8 9 10; do
		seen=$(ip -6 -o addr show dev "$dev" scope global | awk '{print $4}' | cut -d/ -f1)
		if [[ -z "$want" && -n "$seen" ]]; then
			printf '%s\n' "$seen"
			return 0
		fi
		if [[ -n "$want" ]] && grep -qx "$want" <<<"$seen"; then
			return 0
		fi
		sleep 1
	done
	return 1
}

wait_named() {
	local _
	echo "vps: waiting for named on 127.0.0.1"
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
		if dig +norecurse +time=1 +tries=1 @127.0.0.1 . NS >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	die "named is not answering on 127.0.0.1"
}

local_bind=no
pool_line=$(site_get UDP_POOL)
pool_line=${pool_line:-10.8.19.0 255.255.255.0}
mapfile -t pool_v4_out < <(pool_v4 "$pool_line")
dns_addr=${pool_v4_out[0]:-}
dns_net=${pool_v4_out[1]:-}
[[ -n "$dns_addr" && -n "$dns_net" ]] || die "could not parse UDP_POOL"
dns_set=$(site_get DNS)
if [[ -z "$dns_set" ]]; then
	printf '\nDNS = %s\n' "$dns_addr" >>site.conf
	echo "vps: wrote DNS=$dns_addr"
	dns_set=$dns_addr
fi
if [[ "$dns_set" == "$dns_addr" ]]; then
	local_bind=yes
fi

if [[ "$local_bind" == yes ]]; then
	echo "vps: bind9 for $dns_addr ($dns_net)"
	# Stock named listens on every address. Do not start it
	# until the tun exists and named.conf.options replaces that.
	sudo_do tee /usr/sbin/policy-rc.d >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
	sudo_do chmod 755 /usr/sbin/policy-rc.d
	set +e
	sudo_do apt-get install -y bind9
	apt_status=$?
	set -e
	sudo_do rm -f /usr/sbin/policy-rc.d
	[[ "$apt_status" -eq 0 ]] || die "apt-get install bind9 failed"
	sudo_do install -d -m 755 /etc/systemd/system/named.service.d
	sudo_do tee /etc/systemd/system/named.service.d/after-tun.conf >/dev/null <<'EOF'
[Unit]
After=openvpn-server@server-udp.service
EOF
fi

echo "vps: make"
make
echo "vps: make deploy"
sudo_do make deploy

# Debian's nftables.conf is a live ruleset, not a comment-only file.
# Keep it. Append the snippet include when that line is absent.
conf=/etc/nftables.conf
include_line='include "/etc/nftables.d/*.nft"'
if [[ ! -f "$conf" ]]; then
	echo "vps: $conf is missing; installing examples/nftables.conf"
	sudo_do install -m 644 "$ROOT/examples/nftables.conf" "$conf"
elif grep -q 'include[[:space:]]*"/etc/nftables.d/\*\.nft"' "$conf"; then
	echo "vps: $conf already includes /etc/nftables.d"
else
	echo "vps: $conf has rules; leaving them and appending the include"
	grep -Ev '^[[:space:]]*(#|$)' "$conf" | sed 's/^/vps: nft: /'
	printf '\n%s\n' "$include_line" | sudo_do tee -a "$conf" >/dev/null
fi
sudo_do install -d -m 755 /etc/nftables.d
sudo_do install -m 644 "$ROOT/examples/99-openvpn-forward.conf" \
	/etc/sysctl.d/99-openvpn-forward.conf
echo "vps: sysctl"
sudo_do sysctl -p /etc/sysctl.d/99-openvpn-forward.conf
echo "vps: nft -f $conf"
sudo_do nft -f "$conf"
echo "vps: enabling nftables and openvpn-server@server-udp"
sudo_do systemctl enable --now nftables
sudo_do systemctl enable --now openvpn-server@server-udp

if [[ "$local_bind" == yes ]]; then
	server_conf=/etc/openvpn/server/server-udp.conf
	[[ -f "$server_conf" ]] || die "missing $server_conf"
	ip6= net6=
	if grep -Eq '^[[:space:]]*server-ipv6[[:space:]]+' "$server_conf"; then
		pool6=$(sed -n 's/^[[:space:]]*server-ipv6[[:space:]]\+//p' "$server_conf" | awk '{print $1; exit}')
		dev=$(sed -n 's/^[[:space:]]*dev[[:space:]]\+//p' "$server_conf" | awk '{print $1; exit}')
		dev=${dev:-tun0}
		echo "vps: waiting for global IPv6 on $dev"
		ip6_out=$(wait_tun6 "$dev") || die "server-ipv6 is set but $dev has no global IPv6"
		# shellcheck disable=SC2086
		mapfile -t ip6_pick < <(python3 - "$pool6" $ip6_out <<'PY'
import ipaddress, sys
pool = ipaddress.ip_network(sys.argv[1], strict=False)
for raw in sys.argv[2:]:
    addr = ipaddress.ip_address(raw)
    if addr in pool:
        print(addr)
        print(pool)
        raise SystemExit(0)
raise SystemExit(1)
PY
		)
		if [[ ${#ip6_pick[@]} -lt 2 ]]; then
			die "no global IPv6 on $dev is inside $pool6"
		fi
		ip6=${ip6_pick[0]}
		net6=${ip6_pick[1]}
		push_line=$(printf 'push "dhcp-option DNS %s"' "$ip6")
		if ! grep -qxF "$push_line" "$server_conf"; then
			printf '%s\n' "$push_line" | sudo_do tee -a "$server_conf" >/dev/null
			echo "vps: push dhcp-option DNS $ip6"
			sudo_do systemctl restart openvpn-server@server-udp
		fi
		wait_tun6 "$dev" "$ip6" || die "tun IPv6 $ip6 is not on $dev"
		echo "vps: tun IPv6 is $ip6"
	else
		echo "vps: no server-ipv6; named stays IPv4"
	fi
	write_named_options "$dns_addr" "$dns_net" "$ip6" "$net6"
	sudo_do tee /usr/local/sbin/openvpn-deploy-resolv >/dev/null <<'EOF'
#!/bin/sh
set -eu
if [ -L /etc/resolv.conf ]; then
	rm -f /etc/resolv.conf
fi
if [ "$(cat /etc/resolv.conf 2>/dev/null || true)" = "nameserver 127.0.0.1" ]; then
	exit 0
fi
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
EOF
	sudo_do chmod 755 /usr/local/sbin/openvpn-deploy-resolv
	sudo_do tee /etc/systemd/system/openvpn-deploy-resolv.service >/dev/null <<'EOF'
[Unit]
Description=Point resolv.conf at local bind
After=network-online.target named.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openvpn-deploy-resolv
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	if systemctl cat systemd-resolved.service >/dev/null 2>&1; then
		echo "vps: masking systemd-resolved"
		sudo_do systemctl mask --now systemd-resolved
	fi
	sudo_do systemctl daemon-reload
	sudo_do named-checkconf
	sudo_do systemctl enable --now named
	wait_named
	sudo_do systemctl enable --now openvpn-deploy-resolv.service
	echo "vps: resolv.conf nameserver 127.0.0.1"
fi

command -v dig >/dev/null || die "dig missing; install bind9-dnsutils"
echo "vps: DNS want $REMOTE A = $ip4"
while true; do
	resolved=$(dig +trace +nodnssec +time=2 +tries=1 "$REMOTE" A |
		awk -v name="${REMOTE}." 'tolower($1)==tolower(name) && $4=="A" { print $5 }' |
		sort -u) || true
	got=$(printf '%s' "$resolved" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	[[ -n "$got" ]] || got="no answer"
	if grep -qx "$ip4" <<<"$resolved"; then
		echo "vps: DNS got $got (want $ip4)"
		break
	fi
	echo "vps: DNS got $got (want $ip4)"
	sleep 5
done

if [[ ! -d "/etc/letsencrypt/live/$REMOTE" ]]; then
	echo "vps: certbot for $REMOTE as $ACME_EMAIL"
	args=(certbot certonly --standalone -d "$REMOTE"
		--non-interactive --agree-tos -m "$ACME_EMAIL")
	if [[ "${ACME_STAGING:-}" == yes ]]; then
		echo "vps: certbot staging"
		args+=(--staging)
	fi
	sudo_do "${args[@]}"
else
	echo "vps: /etc/letsencrypt/live/$REMOTE already exists"
fi
if [[ -x /usr/lib/bootstash/letsencrypt-deploy ]]; then
	echo "vps: letsencrypt-deploy sync"
	sudo_do /usr/lib/bootstash/letsencrypt-deploy sync
fi
sudo_do systemctl enable --now certbot.timer
if ! sudo_do test -f "/etc/bootstash/certs/$REMOTE/fullchain.pem" ||
	! sudo_do test -f "/etc/bootstash/certs/$REMOTE/privkey.pem"; then
	sudo_do ls -la "/etc/bootstash/certs/$REMOTE" >&2 || true
	die "bootstash certs for $REMOTE are missing after letsencrypt-deploy sync"
fi
echo "vps: certificate files are in /etc/bootstash/certs/$REMOTE"

echo "vps: OpenVPN is up. bootstash is not started."
echo "vps: from your machine, launch/create-vm-do.sh sets the login and starts bootstash."
