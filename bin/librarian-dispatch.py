#!/usr/bin/env python3
"""Stream a chat-completion from a local vllm-mlx model with OBSERVABLE progress.

Why this exists / gotchas it fixes:
  * The local SimpleEngine is a serialized single-slot engine. A big NON-streaming request
    that the client disconnects from (e.g. a foreground curl hitting a 120s tool timeout)
    WEDGES the slot — every later request 503s "text_generation_busy" with prompt=0:
    completion=0 (the "zombie server"). Streaming + consuming the SSE continuously avoids it.
  * We want to SEE progress to tell "still generating" from "stuck". User preference:
    streaming/observable dispatch over silent blocking calls.

Design: curl (-sN) owns the HTTP stream (robust — no Python socket-resume bug). A watchdog
THREAD prints a heartbeat every HEARTBEAT s regardless of whether tokens are flowing, so a
long prefill shows "alive" ticks and a real stall (no new data for STALL s) is flagged —
without ever interrupting the read.

Usage:
  librarian-dispatch.py --port PORT --payload BODY.json --outdir DIR

BODY.json is a standard chat-completions request body (this script forces stream=true), e.g.:
  {"model":"<alias-or-spoof>","max_tokens":800,
   "messages":[{"role":"user","content":"<role + task + inputs + output spec>"}]}

Assistant text streams to DIR/output.txt as it arrives. On completion writes DIR/done
(json: tokens/chars/usage/elapsed). Exit 0 on completion, 2 on HTTP/engine error, 3 transport.
NOTE: takes a JSON body file (--payload), NOT --prompt/--model flags.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

HEARTBEAT = 6    # seconds between progress heartbeats
STALL = 30       # seconds with no new data before we consider a stall
CPU_BUSY = 15.0  # server %CPU above which "no tokens yet" means prefilling, not hung


def _pid_on_port(port):
    """PID of the process LISTENING on `port` (the vllm server), or None."""
    try:
        out = subprocess.run(
            ["lsof", "-nP", "-iTCP:%s" % port, "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=3).stdout.split()
        return int(out[0]) if out else None
    except Exception:
        return None


def _cpu_pct(pid):
    """Current %CPU of `pid` (macOS `ps`), or None if it can't be read."""
    if not pid:
        return None
    try:
        out = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=3).stdout.strip()
        # macOS `ps` honors the locale decimal separator (e.g. "0,1" under a German locale),
        # which plain float() can't parse — normalize the comma before converting.
        return float(out.replace(",", ".")) if out else None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--payload", required=True)
    ap.add_argument("--outdir", required=True)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    body = json.load(open(a.payload))
    body["stream"] = True
    body.setdefault("stream_options", {"include_usage": True})
    req_path = os.path.join(a.outdir, "_req.json")
    json.dump(body, open(req_path, "w"))
    url = "http://localhost:%s/v1/chat/completions" % a.port

    out_path = os.path.join(a.outdir, "output.txt")
    out = open(out_path, "w")

    st = {"t0": time.time(), "last_data": time.time(), "ntok": 0, "chars": 0,
          "done": False, "tail": "", "srv_pid": None}

    def watchdog():
        while not st["done"]:
            time.sleep(HEARTBEAT)
            if st["done"]:
                break
            now = time.time()
            since = now - st["last_data"]
            flag = ""
            if since >= STALL:
                # No new tokens for a while — but a cold prefill of a large prompt is
                # legitimately slow (tok~0 while the engine is busy). Distinguish hung from
                # working by the SERVER's CPU: >0 = prefilling, ~0 = genuinely stuck.
                if st["srv_pid"] is None:
                    st["srv_pid"] = _pid_on_port(a.port)
                cpu = _cpu_pct(st["srv_pid"])
                if cpu is None:
                    flag = "  ⚠ no data %ds (possible stall; CPU unknown)" % int(since)
                elif cpu >= CPU_BUSY:
                    flag = "  ⏳ no tokens %ds but server CPU %.0f%% (prefilling, not hung)" % (int(since), cpu)
                else:
                    flag = "  ⚠ no data %ds AND server CPU %.0f%% (likely HUNG)" % (int(since), cpu)
            print("[t=%ds tok~%d last+%ds]%s …%s" % (
                int(now - st["t0"]), st["ntok"], int(since), flag, st["tail"]), flush=True)

    print("[dispatch] POST %s model=%s payload=%dB stream=on" % (
        url, body.get("model", "?"), os.path.getsize(req_path)), flush=True)

    proc = subprocess.Popen(
        ["curl", "-sN", "-X", "POST", url, "-H", "Content-Type: application/json",
         "--data-binary", "@" + req_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    wd = threading.Thread(target=watchdog, daemon=True)
    wd.start()

    got_data = False
    raw_nonsse = []
    try:
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            if not line.startswith("data:"):
                raw_nonsse.append(line)      # capture error bodies (e.g. 503 JSON)
                continue
            chunk = line[5:].strip()
            if chunk == "[DONE]":
                break
            try:
                obj = json.loads(chunk)
            except Exception:
                continue
            choices = obj.get("choices") or [{}]
            delta = (choices[0].get("delta") or {}).get("content") or ""
            if delta:
                got_data = True
                out.write(delta)
                out.flush()
                st["ntok"] += 1
                st["chars"] += len(delta)
                st["last_data"] = time.time()
                st["tail"] = (st["tail"] + delta)[-70:].replace("\n", " ")
            if obj.get("usage"):
                st["usage"] = obj["usage"]
    finally:
        st["done"] = True
        out.close()
        proc.wait()

    elapsed = int(time.time() - st["t0"])
    usage = st.get("usage")
    if not got_data:
        body_txt = " ".join(raw_nonsse)[:400] or ("curl stderr: " +
                    proc.stderr.read().decode("utf-8", "replace")[:200])
        print("[dispatch] NO DATA (t=%ds). Engine/HTTP response: %s" % (elapsed, body_txt),
              flush=True)
        return 2
    print("[dispatch] DONE t=%ds tok~%d chars=%d usage=%s" % (
        elapsed, st["ntok"], st["chars"], usage), flush=True)
    json.dump({"tokens": st["ntok"], "chars": st["chars"], "usage": usage, "elapsed": elapsed},
              open(os.path.join(a.outdir, "done"), "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
