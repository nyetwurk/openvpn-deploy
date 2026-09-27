# Sourced by the other vps/ scripts. Not run directly.

set -euo pipefail

VPS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$VPS/.." && pwd)
cd "$ROOT"

die() {
	echo "vps: $*" >&2
	exit 1
}

sudo_do() {
	sudo -n "$@"
}

load_env() {
	local env_file=/etc/openvpn-deploy.env
	if [[ -f "$env_file" ]]; then
		set -a
		# shellcheck disable=SC1090
		source "$env_file"
		set +a
	fi
	export DEBIAN_FRONTEND=noninteractive
}

require_user() {
	[[ "$(id -u)" -eq 0 ]] && die "run as the image user, not root"
	if ! sudo_do true; then
		die "passwordless sudo is required"
	fi
}

require_remote() {
	: "${REMOTE:?}"
	[[ "$REMOTE" != "example.com" ]] || die "REMOTE=example.com is not allowed"
	if [[ "$REMOTE" =~ ^[0-9.]+$ ]]; then
		die "REMOTE must be a DNS name, not an address"
	fi
	[[ "$REMOTE" == *.* ]] || die "REMOTE must be a DNS name"
}
