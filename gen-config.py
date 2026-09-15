#!/usr/bin/python3

"""Emit OpenVPN confs and client profiles. Stdlib only."""

from __future__ import annotations

import os
import pwd
import re
import string
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"@[A-Z][A-Z0-9_]*@")


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


def parse_kv(args: list[str]) -> dict[str, str]:
    overlay: dict[str, str] = {}
    for kv in args:
        if "=" not in kv:
            die("usage: gen-config.py server [TEMPLATE [NAME=value ...]]")
        name, val = kv.split("=", 1)
        overlay[name] = val
    return overlay


def cmd_server(argv: list[str]) -> None:
    if argv and "=" not in argv[0]:
        path = Path(argv[0])
        kv = argv[1:]
    else:
        path = Path("server.conf.in")
        kv = argv
    if not path.is_file():
        die(f"gen-config.py server: missing {path}")
    mapping = dict(os.environ)
    mapping.update(parse_kv(kv))
    sys.stdout.write(subst_text(path.read_text(), mapping, str(path)))


def login_name() -> str:
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
    conf = Path(argv[2] if len(argv) > 2 else "server-udp.conf")
    out = Path(argv[3] if len(argv) > 3 else f"client/{client}.ovpn")
    remote = os.environ.get("REMOTE") or server

    if not conf.is_file():
        die(f"gen-config.py client: missing {conf}")

    port = conf_field(conf, "port", "1194")
    proto = conf_field(conf, "proto", "udp")
    mssfix = conf_field(conf, "mssfix", "1360")
    print(f"got {conf} {port} {proto} -> {out}", file=sys.stderr)

    mapping = dict(os.environ)
    mapping.update(
        REMOTE=remote,
        SERVER=server,
        PORT=port,
        PROTO=proto,
        MSSFIX=mssfix,
    )
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
        + pem_block(Path("tc.key"), "BEGIN OpenVPN Static key V1", "END OpenVPN Static key V1")
        + "\n</tls-crypt>\n"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(data)
    os.chmod(out, 0o600)


def main() -> None:
    if len(sys.argv) < 2:
        die("usage: gen-config.py server [TEMPLATE [NAME=value ...]]\n       gen-config.py client SERVER_CN [CLIENT [CONF [OUT]]]")
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "server":
        cmd_server(rest)
    elif cmd == "client":
        cmd_client(rest)
    else:
        die(f"gen-config.py: unknown command {cmd}")


if __name__ == "__main__":
    main()
