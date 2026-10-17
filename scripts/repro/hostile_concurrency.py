#!/usr/bin/env python3
"""Concurrent hostile-input stress for the HTTP server.

Several threads POST a mix of the real sample PDF and randomly mutated
fixtures (which force MuPDF repair paths) to /render, /text and /info.
Pass criterion: the server process is still alive and answering /health.

Usage: python3 scripts/repro/hostile_concurrency.py URL [seconds] [threads] [seed]
"""
import glob
import os
import random
import sys
import threading
import time

import httpx

url = sys.argv[1]
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 60
nthreads = int(sys.argv[3]) if len(sys.argv) > 3 else 8
seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
corpus = [open(p, "rb").read() for p in sorted(glob.glob(os.path.join(root, "tests", "fixtures", "*.pdf")))]
sample = open(os.path.join(root, "examples", "example.pdf"), "rb").read()
tokens = [b"-1", b"0", b" 0 R", b"<<", b">>", b"[", b"]", b"obj", b"endobj", b"stream", b"/Length 0", b"xref", b"%%EOF"]


def mutate(rng, data):
    b = bytearray(data)
    for _ in range(1 + rng.randrange(6)):
        if not b:
            b = bytearray(b"%")
        pos = rng.randrange(len(b))
        op = rng.randrange(4)
        if op == 0:
            b[pos] = rng.randrange(256)
        elif op == 1:
            del b[pos:pos + 1 + rng.randrange(32)]
        elif op == 2:
            b[pos:pos] = rng.choice(tokens)
        else:
            del b[pos + rng.randrange(max(1, len(b) - pos)):]
    return bytes(b)


stats = {"sent": 0, "status": {}, "exc": 0}
lock = threading.Lock()
deadline = time.time() + duration


def worker(tid):
    rng = random.Random(seed * 1000 + tid)
    with httpx.Client(timeout=60) as client:
        while time.time() < deadline:
            r = rng.random()
            if r < 0.4:
                data = sample  # real document: exercises shared caches/store
            elif r < 0.6:
                data = mutate(rng, sample[: rng.randrange(1, len(sample))])
            else:
                data = mutate(rng, rng.choice(corpus))
            ep = rng.choice(["/render", "/text", "/info"])
            fields = {"page": str(rng.randrange(4)), "scale": "0.5"}
            try:
                resp = client.post(url + ep, files={"file": ("x.pdf", data, "application/pdf")}, data=fields)
                code = resp.status_code
            except Exception:  # noqa: BLE001
                code = "exc"
            with lock:
                stats["sent"] += 1
                stats["status"][code] = stats["status"].get(code, 0) + 1


threads = [threading.Thread(target=worker, args=(i,)) for i in range(nthreads)]
for t in threads:
    t.start()
for t in threads:
    t.join()
try:
    alive = httpx.get(url + "/health", timeout=5).status_code == 200
except Exception:  # noqa: BLE001
    alive = False
print(f"requests={stats['sent']} status_counts={dict(sorted(stats['status'].items(), key=str))} server_alive={alive}")
sys.exit(0 if alive and "exc" not in stats["status"] else 1)
