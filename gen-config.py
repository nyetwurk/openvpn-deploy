#!/usr/bin/python3
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

"""Emit OpenVPN confs, client profiles, nft fragments, and Make vars. Stdlib only."""

from __future__ import annotations

import ipaddress
import os
import pwd
import re
import string
import subprocess
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"@[A-Z][A-Z0-9_]*@")
ASSIGN = re.compile(r"^([A-Z][A-Z0-9_]*)\s*=\s*(.*)$")
SITE_CONF = Path(os.environ.get("SITE_CONF", "site.conf"))

DEFAULTS = {
    "REMOTE": "",
    "SERVER_CN": "",
    "ENABLE_UDP": "yes",
    "ENABLE_TCP": "no",
    "UDP_PORT": "1194",
    "TCP_PORT": "443",
    "UDP_DEV": "tun0",
    "TCP_DEV": "tun1",
    "UDP_POOL": "10.8.19.0 255.255.255.0",
    "TCP_POOL": "10.8.20.0 255.255.255.0",
    "ENABLE_IPV6": "yes",
    "UDP_POOL6": "",
    "TCP_POOL6": "",
    "LAN_ROUTE": "",
    "DNS": "",
    "STATE_DIR": "/var/lib/openvpn-server",
    "UDP_IPP": "",
    "TCP_IPP": "",
    "MSSFIX": "1360",
    "REDIRECT_GATEWAY": "redirect-gateway def1 bypass-dhcp",
    "PORT_SHARE": "",
    "TCP_LISTEN": "",
    "WAN_IF": "eth0",
    "CLIENTS": "",
    "BOOTSTASH": "auto",
    "DUPLICATE_CN": "no",
}


class AtTemplate(string.Template):
    delimiter = "@"
    idpattern = r"[A-Z][A-Z0-9_]*"
    flags = 0
    pattern = r"""
        @(?:
            (?P<escaped>@) |
            (?P<named>[A-Z][A-Z0-9_]*)@ |
            (?P<braced>[A-Z][A-Z0-9_]*)@ |
            (?P<invalid>)
        )
    """


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def subst_text(template: str, mapping: dict[str, str], source: str) -> str:
    try:
        out = AtTemplate(template).substitute(mapping)
    except KeyError as exc:
        name = exc.args[0]
        die(f"gen-config.py: {source}: @{name}@ is unset")
    except ValueError as exc:
        die(f"gen-config.py: {source}: {exc}")
    leftover = PLACEHOLDER.findall(out)
    if leftover:
        die(f"gen-config.py: unsubstituted placeholder in {source}: {' '.join(leftover)}")
    return out


def write_out(data: str, dest: Path | None, mode: int = 0o644) -> None:
    if dest is None:
        sys.stdout.write(data)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(data)
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    os.replace(tmp, dest)
    os.chmod(dest, mode)


def require_file(path: Path) -> Path:
    if not path.is_file():
        die(f"gen-config.py: missing {path}")
    return path


def subst_file(path: Path, mapping: dict[str, str]) -> str:
    text = subst_text(require_file(path).read_text(), mapping, str(path))
    if not text.endswith("\n"):
        text += "\n"
    return text


def expect_argv(argv: list[str], usage_msg: str, min_n: int = 0, max_n: int = 0) -> None:
    if not (min_n <= len(argv) <= max_n):
        die(f"usage: gen-config.py {usage_msg}")


def out_path(argv: list[str], index: int = 0, default: Path | None = None) -> Path | None:
    return Path(argv[index]) if len(argv) > index else default


def fill_empty(cfg: dict[str, str], key: str, value: str) -> None:
    stripped = cfg[key].strip()
    cfg[key] = stripped if stripped else value


def if_set(value: str, text: str) -> str:
    return text if value.strip() else ""


def with_value(value: str, fmt: str) -> str:
    value = value.strip()
    return fmt.format(value) if value else ""


def hostname_f() -> str:
    try:
        remote = subprocess.check_output(["hostname", "-f"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"gen-config.py: hostname -f failed: {exc}")
    if not remote:
        die("gen-config.py: hostname -f returned empty")
    return remote


def parse_site(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = ASSIGN.match(line)
        if not m:
            die(f"gen-config.py: {path}:{lineno}: expected KEY = value")
        key, val = m.group(1), m.group(2).rstrip()
        if key not in DEFAULTS:
            die(f"gen-config.py: {path}:{lineno}: unknown key {key}")
        out[key] = val
    return out


def init_site_text(remote: str) -> str:
    return (
        "# Site config for gen-config.py.\n"
        "# Other options: examples/site.conf\n"
        f"REMOTE = {remote}\n"
    )


def require_site_conf() -> None:
    if SITE_CONF.is_file():
        return
    remote = hostname_f()
    write_out(init_site_text(remote), SITE_CONF)
    die(
        f"wrote {SITE_CONF} (REMOTE = {remote})\n"
        f"Edit {SITE_CONF}, then run make again."
    )


def load_site() -> dict[str, str]:
    require_site_conf()
    cfg = dict(DEFAULTS)
    cfg.update(parse_site(SITE_CONF))
    fill_empty(cfg, "REMOTE", hostname_f())
    if cfg["REMOTE"] == "example.com":
        die("gen-config.py: REMOTE=example.com is not allowed")
    fill_empty(cfg, "SERVER_CN", cfg["REMOTE"])
    fill_empty(cfg, "STATE_DIR", DEFAULTS["STATE_DIR"])
    state = cfg["STATE_DIR"]
    fill_empty(cfg, "UDP_IPP", f"{state}/ipp.txt")
    fill_empty(cfg, "TCP_IPP", f"{state}/ipp-tcp.txt")
    fill_empty(cfg, "CLIENTS", login_name())
    fill_empty(cfg, "BOOTSTASH", DEFAULTS["BOOTSTASH"])
    if cfg["BOOTSTASH"] not in ("auto", "no"):
        die("gen-config.py: BOOTSTASH must be auto or no")
    fill_empty(cfg, "DUPLICATE_CN", DEFAULTS["DUPLICATE_CN"])
    if cfg["DUPLICATE_CN"] not in ("yes", "no"):
        die("gen-config.py: DUPLICATE_CN must be yes or no")
    fill_empty(cfg, "WAN_IF", DEFAULTS["WAN_IF"])
    fill_empty(cfg, "ENABLE_IPV6", DEFAULTS["ENABLE_IPV6"])
    if cfg["ENABLE_IPV6"] not in ("yes", "no"):
        die("gen-config.py: ENABLE_IPV6 must be yes or no")
    if cfg["ENABLE_IPV6"] == "yes":
        protos = enabled_protos(cfg)
        if not protos:
            die("gen-config.py: ENABLE_IPV6=yes needs ENABLE_UDP or ENABLE_TCP")
        wan = None
        for proto in protos:
            key = f"{proto.upper()}_POOL6"
            if not cfg[key].strip():
                if wan is None:
                    wan = wan_gua(cfg["WAN_IF"])
                    if wan is None:
                        die(
                            "gen-config.py: ENABLE_IPV6=yes needs a global IPv6 on "
                            f"{cfg['WAN_IF']} or {key}"
                        )
                cfg[key] = pool6_from_wan(wan, 0x19 if proto == "udp" else 0x20)
            cfg[key] = require_pool6(cfg[key], key)
    share = cfg["PORT_SHARE"].strip()
    listen = cfg["TCP_LISTEN"].strip()
    cfg["PORT_SHARE"] = share
    cfg["TCP_LISTEN"] = listen
    if share and listen:
        die("gen-config.py: PORT_SHARE and TCP_LISTEN cannot both be set")
    if share or listen:
        if cfg["ENABLE_TCP"] != "yes":
            die("gen-config.py: PORT_SHARE and TCP_LISTEN need ENABLE_TCP=yes")
        if share:
            require_ipv4_host_port(share, "PORT_SHARE")
        if listen:
            require_ipv4_host_port(listen, "TCP_LISTEN")
    return cfg


def enabled_protos(cfg: dict[str, str]) -> list[str]:
    return [p for p in ("udp", "tcp") if cfg[f"ENABLE_{p.upper()}"] == "yes"]


def proto_val(cfg: dict[str, str], proto: str, name: str) -> str:
    return cfg[f"{proto.upper()}_{name}"]


def pool_to_cidr(pool: str) -> str:
    parts = pool.split()
    if len(parts) != 2:
        die(f"gen-config.py: expected 'address netmask' pool, got {pool!r}")
    addr, mask = parts
    try:
        return str(ipaddress.IPv4Network(f"{addr}/{mask}", strict=False))
    except ValueError as exc:
        die(f"gen-config.py: {exc}")


def wan_gua(ifname: str) -> ipaddress.IPv6Interface | None:
    path = Path("/proc/net/if_inet6")
    if not path.is_file():
        return None
    cands: list[tuple[bool, ipaddress.IPv6Interface]] = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) != 6 or parts[5] != ifname:
            continue
        hexaddr, _idx, plen_hex, scope_hex, flags_hex, _iface = parts
        scope = int(scope_hex, 16)
        flags = int(flags_hex, 16)
        plen = int(plen_hex, 16)
        if scope != 0:
            continue
        if flags & 0x68:  # dadfailed | deprecated | tentative
            continue
        addr = ipaddress.IPv6Address(int(hexaddr, 16))
        if not addr.is_global:
            continue
        try:
            iface = ipaddress.IPv6Interface((addr, plen))
        except ValueError:
            continue
        cands.append((not bool(flags & 0x80), iface))
    if not cands:
        return None
    cands.sort(key=lambda item: (item[0], int(item[1].ip)))
    return cands[0][1]


def pool6_from_wan(wan: ipaddress.IPv6Interface, tag: int) -> str:
    net = wan.network
    if net.prefixlen > 96:
        die(f"gen-config.py: {wan} is too small for a /112 pool; set UDP_POOL6 / TCP_POOL6")
    start = ((net.prefixlen + 15) // 16) * 16
    if start > 96:
        die(f"gen-config.py: {net} cannot host a tagged /112; set UDP_POOL6 / TCP_POOL6")
    pool_int = int(net.network_address) | (tag << (128 - start - 16))
    pool = ipaddress.IPv6Network((pool_int, 112))
    if wan.ip in pool:
        die(
            f"gen-config.py: derived {pool} contains WAN {wan.ip}; "
            "set UDP_POOL6 / TCP_POOL6"
        )
    if not pool.subnet_of(net):
        die(f"gen-config.py: derived {pool} is outside {net}")
    return str(pool)


def require_ipv4_host_port(value: str, key: str) -> tuple[str, str]:
    parts = value.split()
    if len(parts) != 2:
        die(f"gen-config.py: {key} must be 'address port'")
    host, port = parts
    try:
        ipaddress.IPv4Address(host)
    except ValueError:
        die(f"gen-config.py: {key}: host must be IPv4")
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        die(f"gen-config.py: {key}: port must be 1-65535")
    return host, port


def require_pool6(value: str, key: str) -> str:
    value = value.strip()
    if not value:
        die(f"gen-config.py: {key} is required when ENABLE_IPV6=yes")
    try:
        net = ipaddress.IPv6Network(value, strict=True)
    except ValueError as exc:
        die(f"gen-config.py: {key}: {exc}")
    if net.prefixlen != 112:
        die(f"gen-config.py: {key} must be a /112")
    if (
        net.is_link_local
        or net.is_multicast
        or net.is_loopback
        or net.network_address == ipaddress.IPv6Address("::")
        or not (net.is_private or net.is_global)
    ):
        die(f"gen-config.py: {key} must be a ULA or global unicast /112")
    return str(net)


def nft_set(items: list[str]) -> str:
    return "{ " + ", ".join(items) + " }"


def server_mapping(cfg: dict[str, str], proto: str) -> dict[str, str]:
    dns = cfg["DNS"]
    ipv6 = cfg["ENABLE_IPV6"] == "yes"
    port = proto_val(cfg, proto, "PORT")
    local = ""
    port_share = ""
    if proto == "tcp":
        listen = cfg["TCP_LISTEN"]
        port_share = cfg["PORT_SHARE"]
        if listen:
            host, port = require_ipv4_host_port(listen, "TCP_LISTEN")
            local = f"local {host}"
    duplicate = cfg["DUPLICATE_CN"] == "yes"
    ipp = "" if duplicate else proto_val(cfg, proto, "IPP")
    pool6 = proto_val(cfg, proto, "POOL6") if ipv6 else ""
    redir = cfg["REDIRECT_GATEWAY"].strip()
    if ipv6 and redir:
        parts = redir.split()
        if "ipv6" not in parts:
            redir = f"{redir} ipv6"
    return {
        "SERVER_CN": cfg["SERVER_CN"],
        "PROTO": proto,
        "PORT": port,
        "DEV": proto_val(cfg, proto, "DEV"),
        "POOL": proto_val(cfg, proto, "POOL"),
        "SERVER_IPV6": with_value(pool6, "server-ipv6 {}"),
        "IPP_PERSIST": with_value(ipp, "ifconfig-pool-persist {}"),
        "DUPLICATE_CN": "duplicate-cn" if duplicate else "",
        "MSSFIX": cfg["MSSFIX"],
        "LOCAL": local,
        "PORT_SHARE": with_value(port_share, "port-share {}"),
        "EXIT_NOTIFY": "explicit-exit-notify 1" if proto == "udp" else "",
        "REDIRECT_GATEWAY_PUSH": with_value(redir, 'push "{}"'),
        "REDIRECT_GATEWAY_IPV6_PUSH": (
            'push "route-ipv6 2000::/3"' if ipv6 and redir else ""
        ),
        "LAN_ROUTE_PUSH": with_value(cfg["LAN_ROUTE"], 'push "route {}"'),
        "DNS_PUSH": with_value(dns, 'push "dhcp-option DNS {}"'),
        "BLOCK_OUTSIDE_DNS_PUSH": if_set(dns, 'push "block-outside-dns"'),
    }


def nft_mapping(cfg: dict[str, str]) -> dict[str, str]:
    protos = enabled_protos(cfg)
    if not protos:
        die("gen-config.py nft: no listeners (ENABLE_UDP/ENABLE_TCP)")
    ifaces = [proto_val(cfg, p, "DEV") for p in protos]
    cidrs = [pool_to_cidr(proto_val(cfg, p, "POOL")) for p in protos]
    out = {
        "WAN_IF": cfg["WAN_IF"],
        "VPN_IF": nft_set(ifaces),
        "VPN_IPV4_NET": nft_set(cidrs),
        "VPN_IPV6_DEFINE": "",
        "VPN_IPV6_FORWARD": "",
        "VPN_IPV6_NAT": "",
    }
    if cfg["ENABLE_IPV6"] == "yes":
        cidrs6 = [proto_val(cfg, p, "POOL6") for p in protos]
        out["VPN_IPV6_DEFINE"] = f"define VPN_IPv6_NET = {nft_set(cidrs6)}"
        out["VPN_IPV6_FORWARD"] = (
            "add rule inet filter forward oifname $WAN_IF ip6 saddr $VPN_IPv6_NET accept"
        )
        wan = wan_gua(cfg["WAN_IF"])
        snat = f"snat to {wan.ip}" if wan else "masquerade"
        out["VPN_IPV6_NAT"] = (
            "\n"
            "table ip6 openvpn\n"
            "delete table ip6 openvpn\n"
            "\n"
            "table ip6 openvpn {\n"
            "\tchain postrouting {\n"
            "\t\ttype nat hook postrouting priority srcnat; policy accept;\n"
            f"\t\toifname $WAN_IF ip6 saddr $VPN_IPv6_NET {snat}\n"
            "\t}\n"
            "}"
        )
    return out


def emit_template(path: Path, mapping: dict[str, str], dest: Path | None, mode: int = 0o644) -> None:
    write_out(subst_file(path, mapping), dest, mode)


def cmd_init_site(argv: list[str]) -> None:
    expect_argv(argv, "init-site")
    require_site_conf()


def cmd_make_vars(argv: list[str]) -> None:
    expect_argv(argv, "make-vars [OUT]", max_n=1)
    dest = out_path(argv, default=Path("server/vars.mk"))
    cfg = load_site()
    protos = enabled_protos(cfg)
    ipps = (
        []
        if cfg["DUPLICATE_CN"] == "yes"
        else [proto_val(cfg, p, "IPP") for p in protos]
    )
    write_out(
        "# Generated from site.conf. Do not edit.\n"
        f"REMOTE := {cfg['REMOTE']}\n"
        f"SERVER_CN := {cfg['SERVER_CN']}\n"
        f"PROTOS := {' '.join(protos)}\n"
        f"IPP_FILES := {' '.join(ipps)}\n"
        f"CLIENTS := {cfg['CLIENTS']}\n"
        f"BOOTSTASH := {cfg['BOOTSTASH']}\n",
        dest,
    )


def cmd_server(argv: list[str]) -> None:
    if not argv or argv[0] not in ("udp", "tcp") or len(argv) > 2:
        die("usage: gen-config.py server udp|tcp [OUT]")
    emit_template(
        Path("server.conf.in"), server_mapping(load_site(), argv[0]), out_path(argv, 1)
    )


def cmd_nft(argv: list[str]) -> None:
    expect_argv(argv, "nft [OUT]", max_n=1)
    emit_template(Path("openvpn.nft.in"), nft_mapping(load_site()), out_path(argv), 0o755)


def login_name() -> str:
    sudo = os.environ.get("SUDO_USER")
    if sudo:
        return sudo
    return pwd.getpwuid(os.getuid()).pw_name


def conf_field(conf: Path, key: str, default: str) -> str:
    prefix = key + " "
    for line in conf.read_text().splitlines():
        if line.startswith(prefix):
            return line.split(None, 1)[1]
    return default


def pem_block(path: Path, begin: str, end: str) -> str:
    lines: list[str] = []
    inside = False
    for line in path.read_text().splitlines():
        if begin in line:
            inside = True
        if inside:
            lines.append(line)
        if inside and end in line:
            break
    if not lines:
        die(f"gen-config.py client: missing PEM block in {path}")
    return "\n".join(lines)


def inline_block(tag: str, body: str) -> str:
    return f"<{tag}>\n{body}\n</{tag}>\n"


def pem_inline(tag: str, path: Path, begin: str, end: str) -> str:
    return inline_block(tag, pem_block(path, begin, end))


def pem_cert(tag: str, path: Path) -> str:
    return pem_inline(tag, path, "BEGIN CERTIFICATE", "END CERTIFICATE")


def cmd_client(argv: list[str]) -> None:
    expect_argv(argv, "client SERVER_CN [CLIENT [CONF [OUT]]]", min_n=1, max_n=4)
    if not argv[0]:
        die("usage: gen-config.py client SERVER_CN [CLIENT [CONF [OUT]]]")
    server = argv[0]
    client = argv[1] if len(argv) > 1 else login_name()
    conf = require_file(out_path(argv, 2, Path("server/server-udp.conf")))
    dest = out_path(argv, 3, Path(f"client/{client}.ovpn"))
    cfg = load_site()
    proto = conf_field(conf, "proto", "udp")
    mapping = {
        "REMOTE": cfg["REMOTE"],
        "SERVER": server,
        "PORT": proto_val(cfg, proto, "PORT"),
        "PROTO": proto,
        "MSSFIX": conf_field(conf, "mssfix", "1360"),
        "BLOCK_IPV6": (
            "# v4-only tunnel\nblock-ipv6" if cfg["ENABLE_IPV6"] != "yes" else ""
        ),
    }
    pki = Path("easy-rsa/pki")
    data = subst_file(Path("client.ovpn.in"), mapping) + "".join(
        [
            pem_cert("ca", pki / "ca.crt"),
            pem_cert("cert", pki / "issued" / f"{client}.crt"),
            pem_inline(
                "key", pki / "private" / f"{client}.key", "BEGIN PRIVATE KEY", "END PRIVATE KEY"
            ),
            pem_inline(
                "tls-crypt",
                Path("server/tc.key"),
                "BEGIN OpenVPN Static key V1",
                "END OpenVPN Static key V1",
            ),
        ]
    )
    write_out(data, dest, 0o600)


def usage() -> None:
    die(
        "usage: gen-config.py init-site\n"
        "       gen-config.py make-vars [OUT]\n"
        "       gen-config.py server udp|tcp [OUT]\n"
        "       gen-config.py nft [OUT]\n"
        "       gen-config.py client SERVER_CN [CLIENT [CONF [OUT]]]"
    )


def main() -> None:
    if len(sys.argv) < 2:
        usage()
    cmd, rest = sys.argv[1], sys.argv[2:]
    fn = globals().get(f"cmd_{cmd.replace('-', '_')}")
    if not callable(fn):
        die(f"gen-config.py: unknown command {cmd}")
    fn(rest)


if __name__ == "__main__":
    main()
