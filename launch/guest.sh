# Sourced by the launch scripts. Not run directly.
# The default user-data path is rebuilt from vps.yaml first.
# Caller sets PREFIX, ROOT, USER_DATA, ip, and ssh_user.
# SSH_PORT defaults to 22. GUEST_PUBLIC=no skips the certificate
# and does not start bootstash (a guest with no public address).

guest_field() {
	sed -n "s/^[[:space:]]*$1=//p" "$USER_DATA" | head -1
}

guest_require_user_data() {
	if [[ "$USER_DATA" == "$ROOT/launch/cloud-init.yaml" ]]; then
		make -C "$ROOT" cloud-init
	fi
	[[ -f "$USER_DATA" ]] || die "pass a user-data file, or copy examples/vps.yaml to vps.yaml"
	grep -Eq '^[[:space:]]*-[[:space:]]+ssh-' "$USER_DATA" || die "set ssh_authorized_keys in $USER_DATA"
	local key
	for key in ARCHIVE_URL BOOTSTASH_DEB_URL REMOTE ACME_EMAIL; do
		grep -Eq "^[[:space:]]*${key}=[^[:space:]#]+" "$USER_DATA" || die "set ${key} in $USER_DATA"
	done
}

guest_say() {
	echo "$PREFIX: $*"
}

guest_ssh_user() {
	local fallback=$1 user
	user=$(guest_field IMAGE_USER)
	echo "${user:-$fallback}"
}

remote_ssh() {
	ssh -n "${ssh_opts[@]}" "$ssh_user@$ip" "$@"
}

guest_ssh() {
	ssh "${ssh_opts[@]}" "$ssh_user@$ip" "$@"
}

guest_boot_failure() {
	echo "$PREFIX: cloud-init failed" >&2
	remote_ssh "sudo cloud-init status --long" 2>/dev/null |
		awk '/^errors:/{s=1} /^recoverable_errors:/{s=0} s' |
		sed "s/^/$PREFIX: /" >&2 || true
	remote_ssh "sudo grep -E 'curl:|^vps:|Failed |returned error' /var/log/cloud-init-output.log" 2>/dev/null |
		sed "s/^/$PREFIX: /" >&2 || true
	exit 1
}

guest_wait() {
	local status
	until remote_ssh "$@" 2>/dev/null; do
		status=$(remote_ssh "cloud-init status 2>/dev/null || sudo cloud-init status" 2>/dev/null || true)
		if [[ "$status" == *error* ]]; then
			guest_boot_failure
		fi
		sleep 5
	done
}

guest_login() {
	local port= target provision json pass pass2
	ssh_opts=(-T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
	if [[ "${SSH_PORT:-22}" != 22 ]]; then
		ssh_opts+=(-p "$SSH_PORT")
		port="-p ${SSH_PORT} "
	fi
	target="${port}${ssh_user}@${ip}"
	guest_say "in another terminal: ssh ${target} sudo tail -f /var/log/cloud-init-output.log"
	guest_say "waiting for ssh"
	until remote_ssh echo connected >/dev/null 2>&1; do
		sleep 5
	done
	guest_say "ssh connected"
	guest_say "provisioning via ssh"

	guest_wait "sudo test -x /usr/sbin/bootstash && sudo grep -q '^PUBLIC_URL=' /etc/default/bootstash"

	provision=$(python3 - "$ROOT/vps.yaml" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit("install python3-yaml")
path = Path(sys.argv[1])
if not path.is_file():
    sys.exit(f"missing {path}")
data = yaml.safe_load(path.read_text()) or {}
value = data.get("PROVISION", "pam")
if value in (None, ""):
    value = "pam"
if value not in ("pam", "google"):
    sys.exit("PROVISION must be pam or google")
print(value)
PY
	) || die "read PROVISION from $ROOT/vps.yaml"

	if [[ "$provision" == google ]]; then
		guest_say "Google steps follow. Ignore the JSON error; the file is sent next."
		guest_ssh "sudo bootstash provision-google -json -" </dev/null || true
		read -r -p "$PREFIX: path to the downloaded client JSON: " json
		[[ -f "$json" ]] || die "no such file: $json"
		guest_ssh "sudo bootstash provision-google -json -" <"$json"
	else
		read -r -s -p "$PREFIX: enter a new password: " pass
		echo
		read -r -s -p "$PREFIX: enter the new password again: " pass2
		echo
		[[ -n "$pass" && "$pass" == "$pass2" ]] || die "passwords do not match"
		printf '%s:%s\n' "$ssh_user" "$pass" | guest_ssh "sudo chpasswd"
		unset pass pass2
	fi

	if [[ "${GUEST_PUBLIC:-yes}" != yes ]]; then
		guest_say "login is set for ${ssh_user}"
		guest_say "not waiting for a certificate for ${remote}"
		guest_say "this guest has no public address, so bootstash is not started"
		return 0
	fi

	guest_say "waiting for the certificate for $remote"
	guest_wait "sudo test -f /etc/bootstash/certs/${remote}/fullchain.pem"
	remote_ssh sudo systemctl enable --now bootstash
	if [[ "$provision" == google ]]; then
		guest_say "paste https://${remote} into OpenVPN Connect"
	else
		guest_say "log in at https://${remote} as ${ssh_user}"
	fi
}
