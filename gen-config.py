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
    "LAN_ROUTE": "",
    "DNS": "",
    "STATE_DIR": "/var/lib/openvpn-server",
    "UDP_IPP": "",
    "TCP_IPP": "",
    "MSSFIX": "1360",
    "REDIRECT_GATEWAY": "redirect-gateway def1 bypass-dhcp",
    "PORT_SHARE": "",
    "WAN_IF": "eth0",
    "CLIENTS": "",
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


def optional_directive(text: str) -> str:
    return text if text.strip() else ""


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
    if not cfg["REMOTE"].strip():
        cfg["REMOTE"] = hostname_f()
    if cfg["REMOTE"] == "example.com":
        die("gen-config.py: REMOTE=example.com is not allowed")
    if not cfg["SERVER_CN"].strip():
        cfg["SERVER_CN"] = cfg["REMOTE"]
    state = cfg["STATE_DIR"].strip() or DEFAULTS["STATE_DIR"]
    cfg["STATE_DIR"] = state
    if not cfg["UDP_IPP"].strip():
        cfg["UDP_IPP"] = f"{state}/ipp.txt"
    if not cfg["TCP_IPP"].strip():
        cfg["TCP_IPP"] = f"{state}/ipp-tcp.txt"
    if not cfg["CLIENTS"].strip():
        cfg["CLIENTS"] = login_name()
    return cfg


def enabled_protos(cfg: dict[str, str]) -> list[str]:
    protos: list[str] = []
    if cfg["ENABLE_UDP"] == "yes":
        protos.append("udp")
    if cfg["ENABLE_TCP"] == "yes":
        protos.append("tcp")
    return protos


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


def nft_set(items: list[str]) -> str:
    return "{ " + ", ".join(items) + " }"


def server_mapping(cfg: dict[str, str], proto: str) -> dict[str, str]:
    dns = cfg["DNS"].strip()
    lan = cfg["LAN_ROUTE"].strip()
    redirect = cfg["REDIRECT_GATEWAY"].strip()
    port_share = cfg["PORT_SHARE"].strip() if proto == "tcp" else ""
    return {
        "SERVER_CN": cfg["SERVER_CN"],
        "PROTO": proto,
        "PORT": proto_val(cfg, proto, "PORT"),
        "DEV": proto_val(cfg, proto, "DEV"),
        "POOL": proto_val(cfg, proto, "POOL"),
        "IPP": proto_val(cfg, proto, "IPP"),
        "MSSFIX": cfg["MSSFIX"],
        "PORT_SHARE": optional_directive(f"port-share {port_share}" if port_share else ""),
        "EXIT_NOTIFY": "explicit-exit-notify 1" if proto == "udp" else "",
        "REDIRECT_GATEWAY_PUSH": optional_directive(f'push "{redirect}"' if redirect else ""),
        "LAN_ROUTE_PUSH": optional_directive(f'push "route {lan}"' if lan else ""),
        "DNS_PUSH": optional_directive(f'push "dhcp-option DNS {dns}"' if dns else ""),
        "BLOCK_OUTSIDE_DNS_PUSH": optional_directive('push "block-outside-dns"' if dns else ""),
    }


def nft_mapping(cfg: dict[str, str]) -> dict[str, str]:
    protos = enabled_protos(cfg)
    if not protos:
        die("gen-config.py nft: no listeners (ENABLE_UDP/ENABLE_TCP)")
    ifaces = [proto_val(cfg, p, "DEV") for p in protos]
    cidrs = [pool_to_cidr(proto_val(cfg, p, "POOL")) for p in protos]
    return {
        "WAN_IF": cfg["WAN_IF"],
        "VPN_IF": nft_set(ifaces),
        "VPN_IPV4_NET": nft_set(cidrs),
    }


def emit_template(path: Path, mapping: dict[str, str], dest: Path | None, mode: int = 0o644) -> None:
    if not path.is_file():
        die(f"gen-config.py: missing {path}")
    write_out(subst_text(path.read_text(), mapping, str(path)), dest, mode)


def cmd_init_site(argv: list[str]) -> None:
    if argv:
        die("usage: gen-config.py init-site")
    require_site_conf()


def cmd_make_vars(argv: list[str]) -> None:
    if len(argv) > 1:
        die("usage: gen-config.py make-vars [OUT]")
    dest = Path(argv[0]) if argv else Path("server/vars.mk")
    cfg = load_site()
    protos = enabled_protos(cfg)
    ipps: list[str] = []
    if "udp" in protos:
        ipps.append(cfg["UDP_IPP"])
    if "tcp" in protos:
        ipps.append(cfg["TCP_IPP"])
    write_out(
        "# Generated from site.conf. Do not edit.\n"
        f"REMOTE := {cfg['REMOTE']}\n"
        f"SERVER_CN := {cfg['SERVER_CN']}\n"
        f"PROTOS := {' '.join(protos)}\n"
        f"IPP_FILES := {' '.join(ipps)}\n"
        f"CLIENTS := {cfg['CLIENTS']}\n",
        dest,
    )


def cmd_server(argv: list[str]) -> None:
    if not argv or argv[0] not in ("udp", "tcp"):
        die("usage: gen-config.py server udp|tcp [OUT]")
    if len(argv) > 2:
        die("usage: gen-config.py server udp|tcp [OUT]")
    dest = Path(argv[1]) if len(argv) > 1 else None
    emit_template(Path("server.conf.in"), server_mapping(load_site(), argv[0]), dest)


def cmd_nft(argv: list[str]) -> None:
    if len(argv) > 1:
        die("usage: gen-config.py nft [OUT]")
    dest = Path(argv[0]) if argv else None
    emit_template(Path("openvpn.nft.in"), nft_mapping(load_site()), dest)


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


def cmd_client(argv: list[str]) -> None:
    if not argv or not argv[0]:
        die("usage: gen-config.py client SERVER_CN [CLIENT [CONF [OUT]]]")
    server = argv[0]
    client = argv[1] if len(argv) > 1 else login_name()
    conf = Path(argv[2] if len(argv) > 2 else "server/server-udp.conf")
    dest = Path(argv[3]) if len(argv) > 3 else Path(f"client/{client}.ovpn")
    remote = load_site()["REMOTE"]

    if not conf.is_file():
        die(f"gen-config.py client: missing {conf}")

    port = conf_field(conf, "port", "1194")
    proto = conf_field(conf, "proto", "udp")
    mssfix = conf_field(conf, "mssfix", "1360")
    print(f"got {conf} {port} {proto} -> {dest}", file=sys.stderr)

    mapping = {
        "REMOTE": remote,
        "SERVER": server,
        "PORT": port,
        "PROTO": proto,
        "MSSFIX": mssfix,
    }
    body = subst_text(Path("client.ovpn.in").read_text(), mapping, "client.ovpn.in")
    if not body.endswith("\n"):
        body += "\n"
    data = (
        body
        + "<ca>\n"
        + pem_block(Path("easy-rsa/pki/ca.crt"), "BEGIN CERTIFICATE", "END CERTIFICATE")
        + "\n</ca>\n"
        + "<cert>\n"
        + pem_block(
            Path(f"easy-rsa/pki/issued/{client}.crt"),
            "BEGIN CERTIFICATE",
            "END CERTIFICATE",
        )
        + "\n</cert>\n"
        + "<key>\n"
        + pem_block(
            Path(f"easy-rsa/pki/private/{client}.key"),
            "BEGIN PRIVATE KEY",
            "END PRIVATE KEY",
        )
        + "\n</key>\n"
        + "<tls-crypt>\n"
        + pem_block(Path("server/tc.key"), "BEGIN OpenVPN Static key V1", "END OpenVPN Static key V1")
        + "\n</tls-crypt>\n"
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
    if cmd == "init-site":
        cmd_init_site(rest)
    elif cmd == "make-vars":
        cmd_make_vars(rest)
    elif cmd == "server":
        cmd_server(rest)
    elif cmd == "nft":
        cmd_nft(rest)
    elif cmd == "client":
        cmd_client(rest)
    else:
        die(f"gen-config.py: unknown command {cmd}")


if __name__ == "__main__":
    main()
