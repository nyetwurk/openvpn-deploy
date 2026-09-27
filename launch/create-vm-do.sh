#!/bin/bash
# Create a DigitalOcean droplet, then set the login.
# Copy examples/vps.yaml to vps.yaml, fill it, then run:
#   launch/create-vm-do.sh
# That rebuilds launch/cloud-init.yaml from vps.yaml.
# PROVISION in vps.yaml defaults to pam (a password for the image user).
# PROVISION: google pipes the client JSON instead.
# Requires doctl on PATH, already authenticated (doctl auth init):
#   go install github.com/digitalocean/doctl/cmd/doctl@latest
# Overrides: DO_NAME, DO_REGION, DO_SIZE, DO_IMAGE, DO_FIREWALL.
# The remote boot does not call DigitalOcean and does not start bootstash.

set -euo pipefail

die() {
	echo "doctl: $*" >&2
	exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=guest.sh
source "$HERE/guest.sh"
PREFIX=doctl
USER_DATA=${1:-$HERE/cloud-init.yaml}
NAME=${DO_NAME:-vpn-test}
REGION=${DO_REGION:-sfo3}
SIZE=${DO_SIZE:-s-1vcpu-1gb}
IMAGE=${DO_IMAGE:-debian-13-x64}
FIREWALL=${DO_FIREWALL:-openvpn-deploy}

command -v doctl >/dev/null || die "install doctl: go install github.com/digitalocean/doctl/cmd/doctl@latest"
guest_require_user_data
doctl account get >/dev/null || die "doctl auth init"
if doctl compute droplet list --format Name --no-header | grep -qx "$NAME"; then
	die "droplet $NAME already exists"
fi

remote=$(guest_field REMOTE)
echo "doctl: $NAME $IMAGE $SIZE in $REGION"
echo "doctl: user-data $USER_DATA"

line=$(doctl compute droplet create "$NAME" \
	--image "$IMAGE" \
	--size "$SIZE" \
	--region "$REGION" \
	--user-data-file "$USER_DATA" \
	--wait \
	--format ID,PublicIPv4 \
	--no-header)
id=${line%%[[:space:]]*}
ip=${line##*[[:space:]]}
[[ -n "$id" && -n "$ip" && "$id" != "$ip" ]] || die "droplet create returned: $line"

inbound="protocol:tcp,ports:22,address:0.0.0.0/0 protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:443,address:0.0.0.0/0 protocol:udp,ports:1194,address:0.0.0.0/0"
outbound="protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0"
fw=$(doctl compute firewall list --format ID,Name --no-header | awk -v n="$FIREWALL" '$2 == n { print $1; exit }')
if [[ -z "$fw" ]]; then
	doctl compute firewall create \
		--name "$FIREWALL" \
		--inbound-rules "$inbound" \
		--outbound-rules "$outbound" \
		--droplet-ids "$id" >/dev/null
else
	doctl compute firewall add-droplets "$fw" --droplet-ids "$id" >/dev/null
fi

ssh_user=$(guest_ssh_user "")
if [[ -z "$ssh_user" ]]; then
	case "$IMAGE" in
	ubuntu*) ssh_user=ubuntu ;;
	*) ssh_user=debian ;;
	esac
fi

echo "doctl: public IPv4 is $ip"
echo "doctl: point $remote at $ip"
guest_login
