#!/usr/bin/env python3
"""Userspace sink for everything the CI egress guard steers off the wire.

Half of the Linux integration tier's egress gate (INTEG-016). The nftables
ruleset installed by `egress_guard_arm.sh` redirects every non-loopback
connection here; this process records where it was headed and closes it.
Nothing is forwarded: a request that reaches this recorder did not leave
the runner, which is the point. Closing immediately (rather than hanging)
keeps a blocked fetch a fast failure, so a suite whose 12-minute per-test
cap already exists does not start hitting it.

Three listeners, each on loopback only:

  * TCP tarpit -- accepts, reads `SO_ORIGINAL_DST` for the destination the
    caller asked for, then waits up to PEEK_WINDOW for the first bytes so
    a TLS ClientHello's SNI or an HTTP `Host:` header can name the host.
    That naming matters: a leak that skips the resolver (hardcoded IP,
    DoH) produces no DNS record at all, and an IP on its own is not a
    reviewable finding.
  * DNS -- answers NXDOMAIN. `/etc/resolv.conf` points at this listener, so
    it sees the name every resolver-using path asks for even when the
    nftables nat hook is unavailable and the guard is running degraded.
  * UDP sink -- anything else (QUIC on 443 above all), recorded by
    destination only.

Output is JSONL, appended and flushed per record so a SIGKILL still leaves
the run's findings on disk. The first occurrence of each distinct
(proto, target) is written when it happens; repeat counts are written as
one `summary` record at shutdown. `egress_report.py` aggregates.
"""

import argparse
import json
import os
import selectors
import signal
import socket
import struct
import sys
import time

# Linux `SO_ORIGINAL_DST` (netfilter), same numeric value under IPPROTO_IP
# and IPPROTO_IPV6. UDP has no accepted socket to ask, so its pre-nat
# destination arrives as an `IP_ORIGDSTADDR` control message instead,
# which the socket has to opt into with `IP_RECVORIGDSTADDR`.
SO_ORIGINAL_DST = 80
IP_RECVORIGDSTADDR = getattr(socket, 'IP_RECVORIGDSTADDR', 20)
IP_ORIGDSTADDR = getattr(socket, 'IP_ORIGDSTADDR', 20)
IPV6_RECVORIGDSTADDR = getattr(socket, 'IPV6_RECVORIGDSTADDR', 74)
IPV6_ORIGDSTADDR = getattr(socket, 'IPV6_ORIGDSTADDR', 74)

PEEK_WINDOW = 0.25  # seconds to wait for a client's first bytes
PEEK_BYTES = 2048
BACKLOG = 128


def _now():
    return round(time.time(), 3)


def _original_dst(sock):
    """The address the client dialled, before the nat hook rewrote it."""
    try:
        if sock.family == socket.AF_INET6:
            raw = sock.getsockopt(socket.IPPROTO_IPV6, SO_ORIGINAL_DST, 28)
            port, addr = struct.unpack_from('!2xH4x16s', raw)
            return socket.inet_ntop(socket.AF_INET6, addr), port
        raw = sock.getsockopt(socket.IPPROTO_IP, SO_ORIGINAL_DST, 16)
        port, addr = struct.unpack_from('!2xH4s', raw)
        return socket.inet_ntop(socket.AF_INET, addr), port
    except OSError:
        # No nat hook in front of us (degraded mode), or a kernel without
        # the option. The connection is still recorded, just unattributed.
        return None, None


def _orig_dst_cmsg(ancdata):
    """Pre-nat destination out of a datagram's control messages."""
    for level, ctype, data in ancdata:
        try:
            if level == socket.IPPROTO_IP and ctype == IP_ORIGDSTADDR:
                port, addr = struct.unpack_from('!2xH4s', data)
                return socket.inet_ntop(socket.AF_INET, addr), port
            if level == socket.IPPROTO_IPV6 and ctype == IPV6_ORIGDSTADDR:
                port, addr = struct.unpack_from('!2xH4x16s', data)
                return socket.inet_ntop(socket.AF_INET6, addr), port
        except (struct.error, ValueError):
            continue
    return None, None


def _recv_dgram(sock):
    """(payload, peer, pre-nat destination) for one datagram."""
    try:
        payload, ancdata, _flags, peer = sock.recvmsg(4096, 512)
    except OSError:
        return None, None, (None, None)
    return payload, peer, _orig_dst_cmsg(ancdata)


def _sni(data):
    """Server name out of a TLS ClientHello, or None.

    Deliberately strict and bounded: this parses attacker-adjacent bytes
    from whatever the app under test dialled, and a wrong answer is worse
    than no answer.
    """
    try:
        if len(data) < 45 or data[0] != 0x16:
            return None
        # TLSPlaintext: type(1) version(2) length(2), then Handshake:
        # msg_type(1) length(3) version(2) random(32) then the variable
        # session id / cipher suites / compression, then extensions.
        if data[5] != 0x01:
            return None
        i = 5 + 4 + 2 + 32
        i += 1 + data[i]                                    # session id
        i += 2 + struct.unpack_from('!H', data, i)[0]       # cipher suites
        i += 1 + data[i]                                    # compression
        if i + 2 > len(data):
            return None
        end = i + 2 + struct.unpack_from('!H', data, i)[0]
        i += 2
        while i + 4 <= min(end, len(data)):
            ext_type, ext_len = struct.unpack_from('!HH', data, i)
            i += 4
            if ext_type != 0x0000:
                i += ext_len
                continue
            # server_name extension: list length(2), name type(1), len(2)
            if i + 5 > len(data) or data[i + 2] != 0x00:
                return None
            name_len = struct.unpack_from('!H', data, i + 3)[0]
            name = data[i + 5:i + 5 + name_len]
            if len(name) != name_len:
                return None
            return name.decode('ascii', 'replace')
        return None
    except (IndexError, struct.error):
        return None


def _http_host(data):
    try:
        head = data.split(b'\r\n\r\n', 1)[0].decode('latin-1')
    except Exception:
        return None
    lines = head.split('\r\n')
    if not lines or ' HTTP/' not in lines[0]:
        return None
    for line in lines[1:]:
        if line.lower().startswith('host:'):
            return line.split(':', 1)[1].strip()
    return None


def _dns_question(payload):
    """(name, qtype, offset just past the question), or (None, None, 0)."""
    if len(payload) < 12:
        return None, None, 0
    if struct.unpack_from('!H', payload, 4)[0] < 1:
        return None, None, 0
    i = 12
    labels = []
    while i < len(payload):
        n = payload[i]
        if n == 0:
            i += 1
            break
        if n & 0xC0:  # a pointer has no business in a question section
            return None, None, 0
        i += 1
        labels.append(payload[i:i + n].decode('ascii', 'replace'))
        i += n
    else:
        return None, None, 0
    if i + 4 > len(payload):
        return '.'.join(labels), None, 0
    qtype = struct.unpack_from('!H', payload, i)[0]
    return '.'.join(labels), qtype, i + 4


def _nxdomain(payload, qend):
    """Minimal NXDOMAIN for a query, echoing only its question section."""
    if qend <= 12 or len(payload) < 2:
        return b''
    rd = payload[2] & 0x01
    flags = 0x8180 | 0x0003 | (0x0100 if rd else 0)
    return payload[:2] + struct.pack('!HHHHH', flags, 1, 0, 0, 0) \
        + payload[12:qend]


class Recorder:
    def __init__(self, path):
        self._fh = open(path, 'a', buffering=1)
        self._seen = {}

    def add(self, proto, target, name=None, **extra):
        # `name` is part of the identity, not just decoration: two
        # connections to one address can be two different hosts behind it,
        # and the SNI is the half a reviewer can act on.
        key = (proto, target, name)
        if key in self._seen:
            self._seen[key] += 1
            return
        self._seen[key] = 1
        record = {'t': _now(), 'proto': proto, 'target': target}
        if name:
            record['name'] = name
        record.update({k: v for k, v in extra.items() if v is not None})
        self._fh.write(json.dumps(record, sort_keys=True) + '\n')
        self._fh.flush()

    def close(self):
        repeats = {'|'.join(x for x in k if x): n
                   for k, n in self._seen.items() if n > 1}
        if repeats:
            self._fh.write(json.dumps(
                {'t': _now(), 'proto': 'summary', 'repeats': repeats},
                sort_keys=True) + '\n')
        self._fh.flush()
        self._fh.close()


def _listeners(port, kind, v6_addr='::1', v4_addr='127.0.0.1'):
    """One socket per family: a v4-mapped listener cannot answer
    `SO_ORIGINAL_DST` for both, so bind them separately and let the v6 one
    fail on a container with no IPv6."""
    made = []
    for family, addr in ((socket.AF_INET, v4_addr), (socket.AF_INET6, v6_addr)):
        try:
            s = socket.socket(family, kind)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            if kind == socket.SOCK_DGRAM:
                opt = ((socket.IPPROTO_IPV6, IPV6_RECVORIGDSTADDR)
                       if family == socket.AF_INET6
                       else (socket.IPPROTO_IP, IP_RECVORIGDSTADDR))
                try:
                    s.setsockopt(opt[0], opt[1], 1)
                except OSError:
                    pass
            s.bind((addr, port))
            if kind == socket.SOCK_STREAM:
                s.listen(BACKLOG)
            s.setblocking(False)
            made.append(s)
        except OSError as exc:
            if family == socket.AF_INET:
                raise
            print(f'egress-recorder: no IPv6 listener on {port}: {exc}',
                  file=sys.stderr)
    return made


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--log', required=True)
    ap.add_argument('--tcp-port', type=int, default=19531)
    ap.add_argument('--udp-port', type=int, default=19532)
    ap.add_argument('--dns-port', type=int, default=53)
    ap.add_argument('--ready-file')
    args = ap.parse_args()

    rec = Recorder(args.log)
    sel = selectors.DefaultSelector()
    pending = {}  # conn -> (deadline, dst, port)

    for s in _listeners(args.tcp_port, socket.SOCK_STREAM):
        sel.register(s, selectors.EVENT_READ, 'tcp-accept')
    for s in _listeners(args.udp_port, socket.SOCK_DGRAM):
        sel.register(s, selectors.EVENT_READ, 'udp')
    for s in _listeners(args.dns_port, socket.SOCK_DGRAM):
        sel.register(s, selectors.EVENT_READ, 'dns')

    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    if args.ready_file:
        with open(args.ready_file, 'w') as fh:
            fh.write(str(os.getpid()))

    def finish(conn, data):
        _deadline, dst, port = pending.pop(conn)
        target = f'{dst}:{port}' if dst else 'unattributed'
        sni, host = _sni(data), _http_host(data)
        rec.add('tcp', target, name=sni or host,
                source='sni' if sni else ('http-host' if host else None))
        try:
            sel.unregister(conn)
        except (KeyError, ValueError):
            pass
        conn.close()

    while running:
        for key, _ in sel.select(timeout=0.1):
            sock, kind = key.fileobj, key.data
            if kind == 'tcp-accept':
                try:
                    conn, _peer = sock.accept()
                except OSError:
                    continue
                dst, port = _original_dst(conn)
                conn.setblocking(False)
                pending[conn] = (time.monotonic() + PEEK_WINDOW, dst, port)
                sel.register(conn, selectors.EVENT_READ, 'tcp-peek')
            elif kind == 'tcp-peek':
                try:
                    finish(sock, sock.recv(PEEK_BYTES))
                except OSError:
                    finish(sock, b'')
            elif kind == 'dns':
                payload, peer, (dst, dport) = _recv_dgram(sock)
                if payload is None:
                    continue
                name, qtype, qend = _dns_question(payload)
                # A query that arrived here through the nat hook rather
                # than through resolv.conf names a resolver the caller
                # chose itself, which is its own finding.
                resolver = f'{dst}:{dport}' if dst and dport != args.dns_port \
                    else None
                rec.add('dns', name or 'unparsed', qtype=qtype,
                        resolver=resolver)
                reply = _nxdomain(payload, qend)
                if reply:
                    try:
                        sock.sendto(reply, peer)
                    except OSError:
                        pass
            elif kind == 'udp':
                payload, _peer, (dst, dport) = _recv_dgram(sock)
                if payload is None:
                    continue
                rec.add('udp', f'{dst}:{dport}' if dst else 'unattributed')

        now = time.monotonic()
        for conn in [c for c, (d, _, _) in pending.items() if d <= now]:
            finish(conn, b'')

    for conn in list(pending):
        finish(conn, b'')
    rec.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
