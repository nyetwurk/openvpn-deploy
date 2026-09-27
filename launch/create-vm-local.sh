#!/bin/bash
# Boot a disposable Debian generic cloud VM on this host.
# The nocloud image has neither cloud-init nor sshd.
# Copy examples/vps.yaml to vps.yaml, fill it, then run:
#   launch/create-vm-local.sh
# That rebuilds launch/cloud-init.yaml from vps.yaml.
# The guest is amd64 and needs KVM. SSH is the image user at
# 127.0.0.1 port 2222 (override with SSH_PORT).
# QEMU stays in the background. The serial log is local-vm/console.log.
# Stop it with kill "$(cat local-vm/qemu.pid)".
# LOCAL_VM_SERIAL=console keeps the serial console on this terminal
# (Ctrl-a x) and skips the login step.
# A local guest has no public address, so this script sets the login
# and does not wait for a certificate. vps/provision.sh still waits
# until REMOTE's A record is the guest.

set -euo pipefail

die() {
	echo "local-vm: $*" >&2
	exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=guest.sh
source "$HERE/guest.sh"
PREFIX=local-vm
GUEST_PUBLIC=no
USER_DATA=${1:-$HERE/cloud-init.yaml}
DIR=$ROOT/local-vm
IMAGE=debian-13-generic-amd64.qcow2
BASE_URL=https://cloud.debian.org/images/cloud/trixie/latest
SSH_PORT=${SSH_PORT:-2222}
MEM=${MEM:-2G}

command -v qemu-system-x86_64 >/dev/null || die "install qemu-system-x86"
command -v qemu-img >/dev/null || die "install qemu-utils"
command -v cloud-localds >/dev/null || die "install cloud-image-utils"
[[ "$(uname -m)" == x86_64 ]] || die "this image is amd64"
[[ -w /dev/kvm ]] || die "/dev/kvm is not writable"
guest_require_user_data
if (echo >/dev/tcp/127.0.0.1/"$SSH_PORT") 2>/dev/null; then
	die "port ${SSH_PORT} is in use"
fi

mkdir -p "$DIR"
base=$DIR/$IMAGE
if [[ ! -f "$base" ]]; then
	echo "local-vm: downloading $IMAGE"
	tmp=$(mktemp "$DIR/$IMAGE.partial.XXXX")
	trap 'rm -f "$tmp"' EXIT
	curl -fL --retry 3 -o "$tmp" "$BASE_URL/$IMAGE"
	curl -fsSL --retry 3 -o "$DIR/SHA512SUMS" "$BASE_URL/SHA512SUMS"
	expect=$(awk '$2 == "'"$IMAGE"'" { print $1; exit }' "$DIR/SHA512SUMS")
	[[ -n "$expect" ]] || die "SHA512SUMS has no $IMAGE"
	got=$(sha512sum "$tmp" | awk '{ print $1 }')
	[[ "$got" == "$expect" ]] || die "checksum mismatch for $IMAGE"
	mv "$tmp" "$base"
	trap - EXIT
fi

# dsmode local applies this DHCP config before cloud-init waits for
# the network. Without it the guest reaches a login prompt and
# hostfwd to port 22 resets.
cat >"$DIR/network.yaml" <<'EOF'
version: 2
ethernets:
  any:
    match:
      name: "en*"
    dhcp4: true
  eth:
    match:
      name: "eth*"
    dhcp4: true
EOF
cloud-localds -m local -N "$DIR/network.yaml" "$DIR/seed.img" "$USER_DATA"
rm -f "$DIR/throwaway.qcow2"
(
	cd "$DIR"
	qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" throwaway.qcow2
)

ssh_user=$(guest_ssh_user debian)
remote=$(guest_field REMOTE)
ip=127.0.0.1
# systemd-firstboot prompts on the Debian nocloud serial console.
# SMBIOS type 11 credentials answer it. Root stays locked.
serial=(-nographic)
if [[ "${LOCAL_VM_SERIAL:-}" != console ]]; then
	: >"$DIR/console.log"
	serial=(-display none -daemonize -serial "file:${DIR}/console.log" -pidfile "$DIR/qemu.pid")
fi
echo "local-vm: ssh -p ${SSH_PORT} ${ssh_user}@${ip}"
if [[ "${LOCAL_VM_SERIAL:-}" == console ]]; then
	echo "local-vm: quit QEMU with Ctrl-a x"
else
	echo "local-vm: serial log is $DIR/console.log"
	echo "local-vm: stop with kill \"\$(cat $DIR/qemu.pid)\""
fi
qemu-system-x86_64 \
	-machine accel=kvm,type=q35 \
	-cpu host \
	-m "$MEM" \
	"${serial[@]}" \
	-smbios type=1,serial=ds=nocloud \
	-smbios type=11,value=io.systemd.credential:firstboot.locale=C.UTF-8 \
	-smbios type=11,value=io.systemd.credential:firstboot.keymap=us \
	-smbios type=11,value=io.systemd.credential:firstboot.timezone=UTC \
	-smbios type=11,value=io.systemd.credential:firstboot.hostname=debian \
	-smbios type=11,value='io.systemd.credential:passwd.hashed-password.root=!' \
	-drive if=virtio,format=qcow2,file="$DIR/throwaway.qcow2" \
	-drive if=virtio,format=raw,file="$DIR/seed.img" \
	-netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
	-device virtio-net-pci,netdev=net0
if [[ "${LOCAL_VM_SERIAL:-}" == console ]]; then
	exit 0
fi
guest_login
