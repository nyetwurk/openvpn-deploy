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


def nft_set(items: list[str]) -> str:
    return "{ " + ", ".join(items) + " }"


def server_mapping(cfg: dict[str, str], proto: str) -> dict[str, str]:
    dns = cfg["DNS"]
    port_share = cfg["PORT_SHARE"] if proto == "tcp" else ""
    return {
        "SERVER_CN": cfg["SERVER_CN"],
        "PROTO": proto,
        "PORT": proto_val(cfg, proto, "PORT"),
        "DEV": proto_val(cfg, proto, "DEV"),
        "POOL": proto_val(cfg, proto, "POOL"),
        "IPP": proto_val(cfg, proto, "IPP"),
        "MSSFIX": cfg["MSSFIX"],
        "PORT_SHARE": with_value(port_share, "port-share {}"),
        "EXIT_NOTIFY": "explicit-exit-notify 1" if proto == "udp" else "",
        "REDIRECT_GATEWAY_PUSH": with_value(cfg["REDIRECT_GATEWAY"], 'push "{}"'),
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
    return {
        "WAN_IF": cfg["WAN_IF"],
        "VPN_IF": nft_set(ifaces),
        "VPN_IPV4_NET": nft_set(cidrs),
    }


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
    ipps = [proto_val(cfg, p, "IPP") for p in protos]
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
    mapping = {
        "REMOTE": load_site()["REMOTE"],
        "SERVER": server,
        "PORT": conf_field(conf, "port", "1194"),
        "PROTO": conf_field(conf, "proto", "udp"),
        "MSSFIX": conf_field(conf, "mssfix", "1360"),
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
