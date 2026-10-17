#!/usr/bin/env bash
# Issue 3 repro: idle / stalled / truncated clients must not block the server.
#
#  A) open IDLE idle TCP sockets (>= worker count), send nothing, then
#     `curl -m 3 /health` must answer.
#  B) a client that sends half a request line and stalls must be dropped
#     (connection closed by the server) within the read timeout.
#  C) Content-Length larger than the body, then client half-closes: expect 400.
#  D) Content-Length larger than the body, client stalls: expect an error
#     response (408) after the read timeout, not a parse of garbage.
#  E) header larger than the limit: expect 431.
#  F) non-numeric Content-Length: expect 400.
#  G) slowloris trickle: one header byte every 0.5s must still be cut off
#     (the head has a total deadline, not just an idle timeout).
#
# Usage: scripts/repro/issue3_slowloris.sh [port] [idle_sockets] [extra server args...]
# Needs python3 (stdlib only) for the raw-socket cases.
set -u
cd "$(dirname "$0")/../.."
PORT="${1:-8080}"; IDLE="${2:-8}"; shift 2 || shift $#
URL="http://127.0.0.1:$PORT"
FAIL=0

./zig-out/bin/mupdf-server "$PORT" "$@" >/tmp/issue3_server.log 2>&1 &
SPID=$!
cleanup() { for fd in "${IDLE_FDS[@]:-}"; do eval "exec ${fd}>&-" 2>/dev/null; done; kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 100); do curl -s -o /dev/null "$URL/health" && break; sleep 0.1; done
grep -m1 workers /tmp/issue3_server.log || echo "  (server prints no worker count)"

echo "== A) $IDLE idle sockets, then GET /health with curl -m 3 =="
IDLE_FDS=()
for i in $(seq 1 "$IDLE"); do
    fd=$((10 + i)); eval "exec ${fd}<>/dev/tcp/127.0.0.1/$PORT"; IDLE_FDS+=("$fd")
done
sleep 0.3
start=$(date +%s.%N)
out=$(curl -s -m 3 -w ' http=%{http_code}' "$URL/health"); rc=$?
end=$(date +%s.%N)
awk -v s="$start" -v e="$end" -v rc="$rc" -v out="$out" 'BEGIN { printf "  curl exit=%d time=%.2fs %s\n", rc, e - s, out }'
[ $rc -ne 0 ] && FAIL=1
for fd in "${IDLE_FDS[@]}"; do eval "exec ${fd}>&-"; done; IDLE_FDS=()

python3 - "$PORT" <<'PY' || FAIL=1
import socket, sys, time
port = int(sys.argv[1])
fail = False

def conn():
    s = socket.create_connection(("127.0.0.1", port))
    return s

def recv_all(s, limit):
    s.settimeout(limit)
    data = b""
    t0 = time.time()
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return data, time.time() - t0, "closed"
            data += chunk
    except socket.timeout:
        return data, time.time() - t0, "still-open"
    except ConnectionResetError:
        return data, time.time() - t0, "reset"

def status(data):
    if not data:
        return "<no response>"
    head, _, body = data.partition(b"\r\n\r\n")
    line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    return f"{line}  body={body[:80].decode(errors='replace')}"

print("== B) stalled partial request line (sent 'POST /te', then nothing) ==")
s = conn(); s.sendall(b"POST /te")
data, dt, how = recv_all(s, 20)
print(f"  after {dt:.1f}s: connection {how}, response: {status(data)}")
if how == "still-open": fail = True
s.close()

print("== C) Content-Length: 100000 but only 10 body bytes, then client half-closes ==")
s = conn()
s.sendall(b"POST /text HTTP/1.1\r\nHost: x\r\nContent-Type: application/pdf\r\nContent-Length: 100000\r\n\r\n%PDF-1.7\n\n")
s.shutdown(socket.SHUT_WR)
data, dt, how = recv_all(s, 20)
print(f"  after {dt:.1f}s: {status(data)}")
if "400" not in status(data) or "ncomplete" not in status(data): fail = True
s.close()

print("== D) Content-Length: 100000 but only 10 body bytes, client stalls ==")
s = conn()
s.sendall(b"POST /text HTTP/1.1\r\nHost: x\r\nContent-Type: application/pdf\r\nContent-Length: 100000\r\n\r\n%PDF-1.7\n\n")
data, dt, how = recv_all(s, 20)
print(f"  after {dt:.1f}s: connection {how}, response: {status(data)}")
if how == "still-open" or not status(data).startswith("HTTP/1.1 4"): fail = True
s.close()

print("== E) 64 KiB of header without terminator ==")
s = conn()
try:
    s.sendall(b"GET /health HTTP/1.1\r\n" + b"X-Pad: " + b"a" * 65536)
except (BrokenPipeError, ConnectionResetError):
    pass
data, dt, how = recv_all(s, 20)
print(f"  after {dt:.1f}s: {status(data)}")
if not status(data).startswith("HTTP/1.1 431"): fail = True
s.close()

print("== F) Content-Length: abc ==")
s = conn()
s.sendall(b"POST /text HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n")
data, dt, how = recv_all(s, 20)
print(f"  after {dt:.1f}s: {status(data)}")
if "400" not in status(data) or "Content-Length" not in status(data): fail = True
s.close()
print("== G) trickle one header byte every 0.5s for up to 30s ==")
s = conn()
t0 = time.time(); how = "still-open"
payload = b"GET /health HTTP/1.1\r\nX-Slow: " + b"a" * 1000
for b in payload:
    try:
        s.sendall(bytes([b]))
    except (BrokenPipeError, ConnectionResetError):
        how = "closed"; break
    s.settimeout(0.5)
    try:
        if s.recv(65536) == b"":
            how = "closed"; break
        how = "closed"; break  # got a response => server cut it off
    except socket.timeout:
        pass
    except ConnectionResetError:
        how = "reset"; break
    if time.time() - t0 > 30:
        break
print(f"  after {time.time() - t0:.1f}s: connection {how}")
if how == "still-open": fail = True
s.close()
sys.exit(1 if fail else 0)
PY

kill -0 $SPID 2>/dev/null && echo "server alive: yes" || { echo "server alive: NO"; FAIL=1; }
curl -s -m 3 -o /dev/null -w "final /health http=%{http_code}\n" "$URL/health" || FAIL=1
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL
