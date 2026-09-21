#!/usr/bin/env python3
"""Loopback-only TCP forwarding into a network-isolated disposable container.
No bridge, published Docker ports, DNS, or changes to the production proxy.
Requires root solely to enter the container's network namespace.
"""
import ctypes
import json
import os
import select
import socket
import subprocess
import threading

CONTAINER = "rsc-private-preview"

def connect(client, port):
    remote = None
    try:
        info = json.loads(subprocess.check_output(["docker", "inspect", CONTAINER]))[0]
        if info["HostConfig"]["NetworkMode"] != "none" or "RSC_DISPOSABLE_CONTAINER=1" not in info["Config"]["Env"]:
            raise RuntimeError("Not the isolated preview container")
        with open(f'/proc/{info["State"]["Pid"]}/ns/net', 'rb') as ns:
            libc = ctypes.CDLL(None, use_errno=True)
            if libc.setns(ns.fileno(), 0) != 0:
                raise OSError(ctypes.get_errno(), "setns")
        remote = socket.create_connection(("127.0.0.1", port), timeout=10)
        client.settimeout(30)
        remote.settimeout(30)
        while True:
            ready, _, _ = select.select([client, remote], [], [], 120)
            if not ready:
                break
            for source in ready:
                data = source.recv(65536)
                if not data:
                    return
                (remote if source is client else client).sendall(data)
    except (OSError, RuntimeError, subprocess.SubprocessError, KeyError, ValueError):
        pass
    finally:
        client.close()
        if remote:
            remote.close()

def listen(port, destination):
    with socket.socket() as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(32)
        while True:
            client, _ = server.accept()
            threading.Thread(target=connect, args=(client, destination), daemon=True).start()

if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit("Root is required to enter the isolated network namespace")
    threading.Thread(target=listen, args=(13001, 3000), daemon=True).start()
    listen(13000, 3001)
