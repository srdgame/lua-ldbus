#!/usr/bin/env python3
"""Probe: does dbus-daemon relay SCM_RIGHTS fds? Raw D-Bus over sockets."""
import os, socket, struct, time

addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
# address like unix:path=/x,guid=... or unix:abstract=y
parts = addr.split(":", 1)[1].split(",")
target = None
for p in parts:
    if p.startswith("path="):
        target = "\0" + p[5:] if False else p[5:]
    elif p.startswith("abstract="):
        target = "\0" + p[9:]
print("bus address:", target[:40], "abstract" in addr)

def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(target)
    s.sendall(b"\0")
    uid = str(os.getuid()).encode().hex()  # hex of ASCII uid string
    s.sendall(f"AUTH EXTERNAL {uid}\r\n".encode())
    buf = b""
    while not buf.endswith(b"\r\n"):
        buf += s.recv(64)
    print("auth:", buf)
    s.sendall(b"BEGIN\r\n")
    return s

def align(n, a): return b"\0" * ((-n) % a)

def marshal_field(key, sig, val):
    f = bytes([key, len(sig)]) + sig.encode() + b"\0"
    f += align(len(f), 4)
    return f + val

def build_msg(mtype, serial, fields, body=b"", flags=0):
    fdata = b""
    for i, (key, sig, val) in enumerate(fields):
        if i > 0:
            fdata += align(len(fdata) + 16, 8)  # entries are 8-aligned
        fdata += marshal_field(key, sig, val)
    hdr = struct.pack("<BBBBIII", ord("l"), mtype, flags, 1, len(body), serial, len(fdata))
    out = hdr + fdata
    out += align(len(out), 8)
    return out + body

def u32(v): return struct.pack("<I", v)

def sval(v):
    raw = v.encode()
    return u32(len(raw)) + raw + b"\0"  # align handled between entries

srv = connect()
cli = connect()

def hello(s, serial):
    m = build_msg(1, serial, [
        (1, "o", sval("/org/freedesktop/DBus")),
        (2, "s", sval("org.freedesktop.DBus")),
        (3, "s", sval("Hello")),
        (6, "s", sval("org.freedesktop.DBus")),
    ])
    s.sendall(m)

hello(srv, 1)
time.sleep(0.3)
first = srv.recv(4096)
print("srv hello reply len:", len(first))
if first:
    print("  ", first[:32].hex())
hello(cli, 1)
time.sleep(0.3)
firstc = cli.recv(4096)
print("cli hello reply len:", len(firstc))

def drain(s):
    s.setblocking(False)
    try:
        data = s.recv(65536)
    except BlockingIOError:
        data = b""
    s.setblocking(True)
    return data

def read_msg(s, timeout=2.0):
    s.settimeout(timeout)
    data = s.recv(65536)
    s.settimeout(None)
    return data

hello_reply_srv = first
hello_reply_cli = firstc
# parse unique name from Hello reply body: last string in body
def unique_name(hello_reply):
    body_len, _, fields_len = struct.unpack_from("<III", hello_reply, 4)
    body_start = (16 + fields_len + 7) & ~7
    body = hello_reply[body_start:body_start + body_len]
    ln = struct.unpack_from("<I", body)[0]
    return body[4:4 + ln].decode()

srv_name = unique_name(hello_reply_srv)
cli_name = unique_name(hello_reply_cli)
print("srv:", srv_name, "cli:", cli_name)

# test 1: cli sends method_call F to srv via daemon
call = build_msg(1, 2, [
    (1, "o", sval("/x")),
    (2, "s", sval("com.example.Fd")),
    (3, "s", sval("F")),
    (6, "s", sval(srv_name)),
])
cli.sendall(call)
time.sleep(0.3)
got = drain(srv)
print("srv received bytes:", len(got))
print("  type byte:", got[1] if got else None)

# test 2: srv replies WITH an fd
a, b = socket.socketpair()
b.send(b"raw-py-secret")
import sys
mode = sys.argv[1] if len(sys.argv) > 1 else "fd"
fields = [
    (5, "u", u32(2)),          # REPLY_SERIAL
    (6, "s", sval(cli_name)),  # DESTINATION
    (8, "g", bytes([1]) + b"h\0"),  # SIGNATURE "h"
]
if mode != "nofield":
    fields.append((9, "u", u32(1)))   # UNIX_FDS = 1
reply = build_msg(2, 2, fields, body=u32(0))
# sendmsg with SCM_RIGHTS
import array
fds = [a.fileno()]
fds_arr = array.array("i", fds)
print("reply len:", len(reply), "mode:", mode)
if mode == "fd":
    sendmsg_out = srv.sendmsg([reply], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds_arr)])
else:
    sendmsg_out = srv.sendall(reply) or len(reply)
print("sendmsg returned:", send_msg := sendmsg_out)
time.sleep(0.5)
got = drain(cli)
print("cli received bytes:", len(got))
if got:
    print("  type byte:", got[1])
    # scan header fields for ERROR_NAME (key 4) / any error text
    fields_len = struct.unpack_from("<I", got, 12)[0]
    fields = got[16:16+fields_len]
    i = 0
    while i < len(fields):
        try:
            key = fields[i]; sl = fields[i+1]
            sig = fields[i+2:i+2+sl]
            i += 2 + sl + 1
            i += (-i) % 4
            if sig == b"s":
                ln = struct.unpack_from("<I", fields, i)[0]
                print(f"  field {key}: {fields[i+4:i+4+ln].decode()}")
                i += 4 + ln + 1
            elif sig == b"u":
                print(f"  field {key}: u={struct.unpack_from('<I', fields, i)[0]}")
                i += 4
            elif sig == b"g":
                i += 1 + fields[i] + 1
            elif sig == b"o":
                ln = struct.unpack_from("<I", fields, i)[0]
                i += 4 + ln + 1
            i += (-i) % 8
        except IndexError:
            break
    # body (error message text)
    body_len = struct.unpack_from("<I", got, 4)[0]
    body_start = (16 + fields_len + 7) & ~7
    print("  body:", got[body_start:body_start+body_len])
EOF