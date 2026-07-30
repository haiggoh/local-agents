#!/usr/bin/env python3
"""direct-route-acceptance.py — validate the direct-routing fork patches against a live server.

Dispatch-only HTTP checks (no interactive session needed) for the three things that make direct
Claude Code -> vllm-mlx routing work on this stack:

  P1.3  system-message normalization  — the chat_template_safety coalescing patch. Multiple /
        non-leading / interleaved system messages must return 200 (pre-patch they 500 with
        "System message must be at the beginning").
  P1.2  output-limit protection       — oversized max_tokens must be predictably REJECTED (not
        over-allocate KV / swap); normal requests unaffected.
  P3.3  system-prefix KV-cache hit     — the MLLM ArraysCache probe patch. Two requests sharing a
        long system prefix: turn 2 should HIT (reuse cached tokens) and be much faster.

Usage:  direct-route-acceptance.py [--port 8000] [--model claude-opus-4-8] [--log ~/.claude/logs/vllm_<port>.log]
Exit 0 if all pass, 1 otherwise.
"""
import argparse, json, os, time, urllib.request, urllib.error

def post(port, path, payload, timeout=90):
    req = urllib.request.Request(f"http://localhost:{port}{path}", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.getcode(), json.loads(r.read().decode(errors="ignore")), time.monotonic()-t0
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read().decode(errors="ignore"))
        except Exception: body = {}
        return e.code, body, time.monotonic()-t0
    except Exception as e:
        return -1, {"_error": str(e)[:160]}, time.monotonic()-t0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--model", default="claude-opus-4-8")
    ap.add_argument("--log", default=None)
    a = ap.parse_args()
    m = a.model; ok = True
    log = a.log or os.path.expanduser(f"~/.claude/logs/vllm_{a.port}.log")

    print("== P1.3 system-message normalization (expect all 200) ==")
    cases = {
        "single leading":   [{"role":"system","content":"S1"},{"role":"user","content":"hi"}],
        "multiple leading": [{"role":"system","content":"S1"},{"role":"system","content":"S2"},{"role":"user","content":"hi"}],
        "non-leading":      [{"role":"user","content":"hi"},{"role":"system","content":"S"},{"role":"user","content":"again"}],
        "interleaved":      [{"role":"system","content":"S1"},{"role":"user","content":"a"},{"role":"assistant","content":"b"},{"role":"system","content":"m"},{"role":"user","content":"c"}],
    }
    for name, msgs in cases.items():
        code,_,_ = post(a.port, "/v1/chat/completions", {"model":m,"max_tokens":8,"messages":msgs})
        good = code == 200; ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] {name}: HTTP {code}")

    print("== P1.2 output-limit (oversized rejected, normal ok) ==")
    for mt, expect in [(64,"ok"), (999999,"reject")]:
        code, body, _ = post(a.port, "/v1/chat/completions", {"model":m,"max_tokens":mt,"messages":[{"role":"user","content":"hi"}]})
        rejected = code != 200 or "exceeds" in json.dumps(body)
        good = (rejected if expect=="reject" else (code==200))
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] max_tokens={mt}: HTTP {code} {'(rejected)' if rejected else '(accepted)'}")

    print("== P3.3 system-prefix KV-cache hit (turn 2 faster + log HIT) ==")
    prefix = "You are a helpful assistant. " * 300
    lat = []
    for turn in (1, 2):
        _, _, dt = post(a.port, "/v1/chat/completions",
                        {"model":m,"max_tokens":4,"messages":[{"role":"system","content":prefix},{"role":"user","content":f"turn {turn}"}]})
        lat.append(dt); print(f"  turn {turn}: {dt:.2f}s")
    hit_line = ""
    try:
        for line in reversed(open(log, errors="ignore").readlines()):
            if "cache HIT" in line or "cache MISS" in line: hit_line = line.strip(); break
    except Exception: pass
    cache_ok = lat[1] < lat[0] * 0.6 or "HIT" in hit_line
    ok &= cache_ok
    print(f"  [{'PASS' if cache_ok else 'FAIL'}] turn2/turn1={lat[1]/max(lat[0],1e-6):.2f}  log: {hit_line[-90:] or '(no cache line)'}")

    print(f"\n=== DIRECT-ROUTE ACCEPTANCE: {'PASS' if ok else 'FAIL'} ===")
    raise SystemExit(0 if ok else 1)

if __name__ == "__main__":
    main()
