#!/bin/bash
# Create a Google Compute Engine instance, then set the login.
# Copy examples/vps.yaml to vps.yaml, fill it, then run:
#   launch/create-vm-gce.sh
# That rebuilds launch/cloud-init.yaml from vps.yaml.
# Requires gcloud on PATH, a project, and credentials:
#   gcloud auth login && gcloud config set project PROJECT
# Overrides: GCE_NAME, GCE_ZONE, GCE_TYPE, GCE_IMAGE_FAMILY, GCE_TAG.
# OS Login is turned off so the SSH key in user-data is the login.
# The remote boot does not call Google and does not start bootstash.

set -euo pipefail

die() {
	echo "gcloud: $*" >&2
	exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=guest.sh
source "$HERE/guest.sh"
PREFIX=gcloud
USER_DATA=${1:-$HERE/cloud-init.yaml}
NAME=${GCE_NAME:-vpn-test}
ZONE=${GCE_ZONE:-us-west1-a}
TYPE=${GCE_TYPE:-e2-micro}
FAMILY=${GCE_IMAGE_FAMILY:-debian-13}
TAG=${GCE_TAG:-openvpn-deploy}

command -v gcloud >/dev/null || die "install gcloud and run: gcloud auth login"
guest_require_user_data
gcloud config get-value project >/dev/null || die "gcloud config set project PROJECT"
if gcloud compute instances describe "$NAME" --zone="$ZONE" >/dev/null 2>&1; then
	die "instance $NAME already exists in $ZONE"
fi

remote=$(guest_field REMOTE)
echo "gcloud: $NAME $FAMILY $TYPE in $ZONE"
echo "gcloud: user-data $USER_DATA"

if ! gcloud compute firewall-rules describe "$TAG" >/dev/null 2>&1; then
	gcloud compute firewall-rules create "$TAG" \
		--allow=tcp:22,tcp:80,tcp:443,udp:1194 \
		--target-tags="$TAG" \
		--source-ranges=0.0.0.0/0 >/dev/null
fi

gcloud compute instances create "$NAME" \
	--zone="$ZONE" \
	--machine-type="$TYPE" \
	--image-family="$FAMILY" \
	--image-project=debian-cloud \
	--metadata=enable-oslogin=FALSE \
	--metadata-from-file=user-data="$USER_DATA" \
	--tags="$TAG" >/dev/null

ip=$(gcloud compute instances describe "$NAME" --zone="$ZONE" \
	--format='get(networkInterfaces[0].accessConfigs[0].natIP)')
[[ -n "$ip" ]] || die "instance $NAME has no public IPv4"
ssh_user=$(guest_ssh_user debian)

echo "gcloud: public IPv4 is $ip"
echo "gcloud: point $remote at $ip"
guest_login
