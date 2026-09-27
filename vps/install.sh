#!/bin/bash
# Copyright (C) 2026 Nye Liu
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Root half of first boot. Picks the image user, copies this tree to
# ~/openvpn-deploy, and runs vps/provision.sh as that user.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ "$(id -u)" -eq 0 ]] || die "run as root"

if [[ ! -e /dev/net/tun ]]; then
	die "TUN device missing; enable /dev/net/tun"
fi

load_env

user=${IMAGE_USER:-}
if [[ -z "$user" ]]; then
	if id -u debian >/dev/null 2>&1; then
		user=debian
	elif id -u ubuntu >/dev/null 2>&1; then
		user=ubuntu
	else
		user=debian
	fi
fi
if ! id -u "$user" >/dev/null 2>&1; then
	useradd --create-home --shell /bin/bash --groups sudo,adm "$user"
else
	usermod -aG adm "$user"
fi
home=$(getent passwd "$user" | cut -d: -f6)
if [[ ! -f "$home/.ssh/authorized_keys" && -f /root/.ssh/authorized_keys ]]; then
	install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
	install -m 600 -o "$user" -g "$user" \
		/root/.ssh/authorized_keys "$home/.ssh/authorized_keys"
fi

if ! sudo -u "$user" sudo -n true 2>/dev/null; then
	printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" \
		>"/etc/sudoers.d/${user}-nopasswd"
	chmod 440 "/etc/sudoers.d/${user}-nopasswd"
fi

dest=$home/openvpn-deploy

if [[ "$ROOT" != "$dest" ]]; then
	install -d -o "$user" -g "$user" "$dest"
	cp -a "$ROOT"/. "$dest"/
fi
chown -R "$user:$user" "$dest"
sudo -u "$user" -H env -u SUDO_USER bash -lc 'cd ~/openvpn-deploy && ./vps/provision.sh'
