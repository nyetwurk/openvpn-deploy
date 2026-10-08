# Why OpenVPN

* A VPN on a host you control
* UDP first; TCP 443 on that same host when UDP is blocked
* Easy mobile client provisioning optional via [bootstash](https://git.nyet.org/bootstash)

## Protocol

* OpenVPN can listen on TCP 443 (`ENABLE_TCP`, `PORT_SHARE` with local
HTTPS, or `TCP_LISTEN` behind another mux).
* WireGuard is UDP-only.
* Tailscale and Headscale can relay over HTTPS (DERP) on their relays, not on your box.

## This setup

Works on a WAN VPS and on a NAT router that already has a firewall.
Deploys an nft fragment when configured to do so (`NFT_DEST`). It does
not replace the existing host firewall or enable new services.

To provision a client, copy `.ovpn` files out of band (`scp`, a laptop, or
standing bootstash) or use bootstash. Profiles are never published as a link.

## Comparison

| | openvpn-deploy | WireGuard | Tailscale / Headscale | Algo / Nyr / angristan |
| --- | --- | --- | --- | --- |
| UDP tunnel | ✅ | ✅ | ✅ | ✅ (usually WG) |
| TCP 443 **on this host** | ✅ | ❌ | ❌ (DERP elsewhere) | ❌ |
| No coordination server | ✅ | ✅ | ❌ | ✅ |
| Leaves the host firewall alone | ✅ | ✅ | ✅ | ❌ |
| Existing NAT router | ✅ | ❌ (DIY) | ❌ (overlay) | ❌ (fresh VPS) |
| No “anyone with the link” profile | ✅ | ❌ if you post it | ❌ (invites) | ✅ (files on a laptop) |

Turnkeys:

- [Algo](https://github.com/trailofbits/algo) (AGPL) — Ansible/cloud-init WireGuard + IKEv2
- [Nyr/wireguard-install](https://github.com/Nyr/wireguard-install) (MIT) — interactive script
- [angristan/wireguard-install](https://github.com/angristan/wireguard-install) (MIT) — interactive script

## License

Copyright (C) 2026 Nye Liu. Licensed under the GNU GPL version 3 or
later. See [LICENSE](LICENSE).
