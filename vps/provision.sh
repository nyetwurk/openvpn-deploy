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
