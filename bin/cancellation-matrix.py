#!/usr/bin/env python3
"""cancellation-matrix.py — T2-3 reliability gate for the single-slot SimpleEngine.

The core question (Action Plan Part 2 §7, §Final): when a client disconnects or times out,
does the local server RETIRE the MLX generation, or does stale work keep holding the single
generation slot and block the next request? Under `wait` admission a stale holder makes every
follow-up QUEUE behind it — the pathological long-tail latency Part 2 warns about. Upstream
#426 (request cancellation + streaming-timeout enforcement) IS in our HEAD 0dd1157, so the
mechanism exists; this measures whether it actually fires on the direct path.

Method: the KEY metric is FOLLOW-UP LATENCY. Start a long generation, abandon it (timeout or
stream-disconnect), then immediately fire a trivial request and time it. Fast follow-up =>
slot was freed (cancellation works). Slow follow-up (~= the long gen's remaining time) =>
stale work held the slot.

Safe: bounded max_tokens, short timeouts, targets the operator on :8000 (no launches, no kills).
Run when the machine is otherwise idle (e.g. after the tournament sweep) for a clean signal.
"""
import argparse, json, socket, ssl, time, urllib.request, urllib.error, threading

def post(port, payload, timeout):
    req = urllib.request.Request(f"http://localhost:{port}/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        r.read()
    return time.monotonic() - t0

def trivial_latency(port):
    t0 = time.monotonic()
    try:
        post(port, {"model": "claude-opus-4-8", "max_tokens": 4,
                    "messages": [{"role": "user", "content": "hi"}]}, timeout=120)
    except Exception as e:
        return -1, f"{type(e).__name__}: {e}"
    return time.monotonic() - t0, "ok"

def long_payload():
    # a generation that would take a while (bounded so it can't run away)
    return {"model": "claude-opus-4-8", "max_tokens": 1500,
            "messages": [{"role": "user", "content":
                          "Write a long detailed numbered list counting slowly from 1 to 300, "
                          "one number per line with a short note each."}]}

def raw_stream_then_disconnect(port, read_seconds):
    """Open a streaming request, read for a bit, then hard-close the socket (disconnect)."""
    body = json.dumps({**long_payload(), "stream": True}).encode()
    s = socket.create_connection(("localhost", port), timeout=10)
    req = (f"POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:{port}\r\n"
           f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
           f"Connection: close\r\n\r\n").encode() + body
    s.sendall(req)
    t0 = time.monotonic(); got = 0
    s.settimeout(read_seconds)
    try:
        while time.monotonic() - t0 < read_seconds:
            chunk = s.recv(4096)
            if not chunk: break
            got += len(chunk)
    except socket.timeout:
        pass
    s.close()  # abrupt disconnect
    return got

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    a = ap.parse_args()
    port = a.port
    print(f"# T2-3 cancellation/admission matrix — operator on :{port}\n")

    base, _ = trivial_latency(port)
    print(f"baseline trivial latency: {base:.2f}s\n")

    # C-2: non-streaming client timeout, then measure follow-up
    print("C-2 non-streaming client TIMEOUT then follow-up:")
    tstart = time.monotonic()
    try:
        post(port, long_payload(), timeout=4)   # client gives up after 4s
        print("  (long request returned within 4s — increase load to test)")
    except Exception as e:
        print(f"  long request abandoned after ~4s ({type(e).__name__})")
    fu, st = trivial_latency(port)
    print(f"  -> follow-up latency: {fu:.2f}s ({st})")
    print(f"     interpretation: ~baseline ({base:.1f}s) = slot freed / OK; "
          f"much larger = stale gen held the slot\n")

    time.sleep(3)

    # C-1: streaming disconnect, then measure follow-up
    print("C-1 streaming DISCONNECT then follow-up:")
    try:
        got = raw_stream_then_disconnect(port, read_seconds=3)
        print(f"  streamed ~{got} bytes then hard-closed the socket")
    except Exception as e:
        print(f"  stream test error: {type(e).__name__}: {e}")
    fu, st = trivial_latency(port)
    print(f"  -> follow-up latency: {fu:.2f}s ({st})")
    print(f"     interpretation: ~baseline = disconnect retired the work; "
          f"much larger = orphaned generation still running\n")

    print("VERDICT GUIDE (Part 2 §6.4 admission gate):")
    print("  follow-ups ~= baseline  -> cancellation/timeout retires MLX work; `wait` admission is safe")
    print("  follow-ups >> baseline  -> stale work holds the single slot; prefer fail_fast + bounded")
    print("                              client retries, or add a bounded cancellation-aware queue")

if __name__ == "__main__":
    main()
