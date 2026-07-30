#!/usr/bin/env python3
"""tournament-dispatch.py — T3-1 Stage-A dispatch tournament for the local stack.

Direct-API smoke test of every on-disk model, one at a time, to rank them for the
operator / architect / reviewer / utility roles WITHOUT touching the verified operator
config. Dispatch = plain HTTP; no Claude Code, no interactive session — so this runs from
ANY shell (even a gateway session) as long as it can reach localhost.

WHAT IT DOES per model (Stage A, from Action Plan Part 1 §16 + Part 3 parser research):
  1. serve it (reuse if already up on --operator-port; else launch on --scratch-port)
  2. /v1/models identity
  3. plain "reply hello"  -> latency, output tokens, stop_reason, verbatim content
  4. forced tool call     -> does it emit STRUCTURED tool_calls? valid JSON args? (agent viability)
  5. streaming            -> does SSE deltas actually stream?
  6. 2nd turn             -> basic multi-turn continuation
  7. records load time + a memory snapshot
Then it KILLS what it launched (never the operator) and moves on.

SAFETY (safe to run unattended, watchable via CC Live):
  - memory preflight before each launch; ABORTS a load if free RAM < size + headroom.
  - bounded readiness (READY_TIMEOUT) and per-probe HTTP timeouts — never hangs.
  - large models (> LARGE_GB) are SKIPPED unless --include-large (Devstral-123B 66G / Scout 57G
    are both large AND parser-limited: Devstral needs upstream #631 [ARGS] which is ABSENT in
    our HEAD, so its tool probe is expected to degrade; Scout is dispatch-only via mlx_lm.server).
  - only kills PIDs it launched on --scratch-port; leaves the operator on --operator-port alone.
  - one model resident at a time on the scratch port (plus the untouched operator).

USAGE:
  tournament-dispatch.py                     # safe subset (<=LARGE_GB), reuse operator on 8000
  tournament-dispatch.py --only kat-coder    # one model
  tournament-dispatch.py --include-large      # also Devstral-123B + Scout (SUPERVISED — heavy)
  tournament-dispatch.py --scratch-port 8002  # where to launch non-operator models

Results -> ~/.claude/logs/tournament-<UTCdate>/results.{json,md}
Parser vocab (verified): auto,mistral,qwen,qwen3_coder,llama,hermes,harmony,gpt-oss,deepseek,
  kimi,granite,nemotron,xlam,functionary,gemma4,glm47,minimax.
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
VENV = f"{HOME}/.local-llm/bin"
MODELS_DIR = f"{HOME}/.models"
CONFIG_DIR = f"{HOME}/.claude/config"
LOG_BASE = f"{HOME}/.claude/logs/vllm"
READY_TIMEOUT = int(os.environ.get("TOURNEY_READY_TIMEOUT", "480"))
LARGE_GB = float(os.environ.get("TOURNEY_LARGE_GB", "40"))
HEADROOM_GB = 10.0  # required free RAM above a model's on-disk size before we launch it

# --- Model registry (dir, parsers, thinking, role hypothesis). serve: "vllm" | "mlx_lm" -------
# tool_parser / reasoning_parser choices come from Part 3's parser research; they are TEST
# CANDIDATES to confirm against raw output, not settled facts.
MODELS = [
    dict(alias="qwen-3.6-operator", dir="Qwen3.6-27B-UD-MLX-4bit", serve="vllm",
         tool_parser="qwen", reasoning_parser=None, thinking="false", role="operator (incumbent)"),
    dict(alias="qwen-3.6-8bit", dir="Qwen3.6-27B-8bit", serve="vllm",
         tool_parser="qwen", reasoning_parser=None, thinking="false", role="operator quality tier"),
    dict(alias="kat-coder", dir="KAT-Coder-V2.5-Dev-OptiQ-4bit", serve="vllm",
         tool_parser="qwen3_coder", reasoning_parser="qwen3", thinking="false",
         role="operator challenger (coding-specialised; tokenizer declares qwen3_coder)"),
    dict(alias="deepseek-r1-architect", dir="DeepSeek-R1-Distill-Qwen-32B-4bit", serve="vllm",
         tool_parser="qwen", reasoning_parser="deepseek_r1", thinking="true",
         role="architect/validator (reasoning; no structured tool_calls expected)"),
    dict(alias="devstral-123b", dir="Devstral-2-123B-Instruct-2512-4bit", serve="vllm",
         tool_parser="mistral", reasoning_parser=None, thinking="false", large=True,
         role="large reviewer (tool probe expected to DEGRADE — upstream #631 [ARGS] ABSENT here)"),
    dict(alias="llama-scout", dir="Llama-4-Scout-17B-16E-Instruct-4bit", serve="mlx_lm",
         tool_parser=None, reasoning_parser=None, thinking=None, large=True,
         role="utility (dispatch-only via mlx_lm.server; served under model-dir id)"),
]

def now(): return time.monotonic()
def utcstamp(): return datetime.now(timezone.utc).strftime("%Y%m%d")

def free_ram_gb():
    """Approx free (free + inactive + speculative) RAM in GB via vm_stat."""
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        page = 4096
        m = re.search(r"page size of (\d+)", out)
        if m: page = int(m.group(1))
        def pages(label):
            mm = re.search(rf"{label}:\s+(\d+)", out)
            return int(mm.group(1)) if mm else 0
        free = (pages("Pages free") + pages("Pages inactive") + pages("Pages speculative")) * page
        return free / 1e9
    except Exception:
        return -1.0

def dir_size_gb(path):
    try:
        out = subprocess.run(["du", "-sk", path], capture_output=True, text=True, timeout=60).stdout
        return int(out.split()[0]) / 1e6
    except Exception:
        return 0.0

def http_json(url, payload=None, timeout=60, stream=False):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"},
                                 method="POST" if data else "GET")
    t0 = now()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if stream:
                chunks = 0
                for line in r:
                    if line.strip().startswith(b"data:"):
                        chunks += 1
                        if chunks >= 3:  # enough to prove streaming
                            break
                return {"_stream_chunks": chunks}, now() - t0
            body = r.read().decode(errors="ignore")
            return json.loads(body), now() - t0
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_body": e.read().decode(errors="ignore")[:300]}, now() - t0
    except Exception as e:
        return {"_error": f"{type(e).__name__}: {e}"[:300]}, now() - t0

def models_up(port):
    d, _ = http_json(f"http://localhost:{port}/v1/models", timeout=4)
    if isinstance(d, dict) and "data" in d:
        return [m.get("id") for m in d["data"]]
    return None

def wait_ready(port, timeout, logf=None):
    deadline = now() + timeout
    while now() < deadline:
        ids = models_up(port)
        if ids:
            return ids
        time.sleep(2)
    return None

def launch_vllm(m, port):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(LOG_BASE), exist_ok=True)
    cfg = f"{CONFIG_DIR}/tourney_{port}.yaml"
    mdir = f"{MODELS_DIR}/{m['dir']}"
    with open(cfg, "w") as f:
        f.write("manager:\n  memory_budget_gb: 48\nmodels:\n"
                f'  - name: "{m["alias"]}"\n    path: "{mdir}"\n'
                f"    max_model_len: 32768\n    kv_cache_quantization_level: 4\n")
    args = [f"{VENV}/vllm-mlx", "serve", "--models-config", cfg, "--port", str(port),
            "--enable-auto-tool-choice", "--tool-call-parser", m["tool_parser"]]
    if m.get("reasoning_parser"):
        args += ["--reasoning-parser", m["reasoning_parser"]]
    env = dict(os.environ, VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION="wait",
               VLLM_MLX_ENABLE_THINKING=str(m.get("thinking") or "false"))
    logf = f"{LOG_BASE}_tourney_{port}.log"
    with open(logf, "w") as lf:
        p = subprocess.Popen(args, stdout=lf, stderr=subprocess.STDOUT, env=env,
                             start_new_session=True)
    return p, logf

def launch_mlx_lm(m, port):
    os.makedirs(os.path.dirname(LOG_BASE), exist_ok=True)
    mdir = f"{MODELS_DIR}/{m['dir']}"
    args = [f"{VENV}/python", "-m", "mlx_lm", "server", "--model", mdir,
            "--host", "127.0.0.1", "--port", str(port), "--max-tokens", "4096"]
    logf = f"{LOG_BASE}_tourney_{port}.log"
    with open(logf, "w") as lf:
        p = subprocess.Popen(args, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    return p, logf

def kill_port(port):
    try:
        out = subprocess.run(["lsof", "-t", f"-i:{port}", "-sTCP:LISTEN"],
                             capture_output=True, text=True, timeout=8).stdout.split()
        for pid in out:
            try: os.killpg(os.getpgid(int(pid)), signal.SIGKILL)
            except Exception:
                try: os.kill(int(pid), signal.SIGKILL)
                except Exception: pass
    except Exception:
        pass

def probe_model(alias, port, model_id, is_reasoner=False):
    """Run the Stage-A probe suite against a served model. Returns a result dict."""
    r = {"identity": model_id}
    # 3. plain hello
    d, lat = http_json(f"http://localhost:{port}/v1/chat/completions", {
        "model": model_id, "max_tokens": 64,
        "messages": [{"role": "user", "content": "Reply with only the single word: hello"}]}, timeout=120)
    if "choices" in d:
        ch = d["choices"][0]
        r["hello"] = {"latency_s": round(lat, 2),
                      "out_tokens": d.get("usage", {}).get("completion_tokens"),
                      "stop_reason": ch.get("finish_reason"),
                      "content": (ch["message"].get("content") or "")[:120]}
    else:
        r["hello"] = {"latency_s": round(lat, 2), "error": d}
    # 4. forced tool call
    d, lat = http_json(f"http://localhost:{port}/v1/chat/completions", {
        "model": model_id, "max_tokens": 256,
        "messages": [{"role": "user", "content": "What is 17*23? Use the multiply tool."}],
        "tools": [{"type": "function", "function": {"name": "multiply",
                   "parameters": {"type": "object", "properties": {
                       "a": {"type": "integer"}, "b": {"type": "integer"}}, "required": ["a", "b"]}}}],
        "tool_choice": "auto"}, timeout=120)
    tc = {"latency_s": round(lat, 2)}
    if "choices" in d:
        ch = d["choices"][0]
        calls = (ch.get("message") or {}).get("tool_calls")
        tc["finish_reason"] = ch.get("finish_reason")
        if calls:
            fn = calls[0].get("function", {})
            args_ok = False
            try: args_ok = isinstance(json.loads(fn.get("arguments") or "{}"), dict)
            except Exception: pass
            tc["structured_tool_call"] = True
            tc["fn_name"] = fn.get("name")
            tc["args_valid_json"] = args_ok
            tc["args"] = (fn.get("arguments") or "")[:80]
        else:
            tc["structured_tool_call"] = False
            tc["content_leak"] = (ch.get("message", {}).get("content") or "")[:120]
    else:
        tc["error"] = d
    r["tool_call"] = tc
    # 5. streaming
    d, lat = http_json(f"http://localhost:{port}/v1/chat/completions", {
        "model": model_id, "max_tokens": 32, "stream": True,
        "messages": [{"role": "user", "content": "Count: one two three"}]}, timeout=60, stream=True)
    r["streaming"] = {"streamed_chunks": d.get("_stream_chunks") if isinstance(d, dict) else None,
                      "ok": bool(isinstance(d, dict) and d.get("_stream_chunks"))}
    # 6. 2nd turn
    d, lat = http_json(f"http://localhost:{port}/v1/chat/completions", {
        "model": model_id, "max_tokens": 64,
        "messages": [{"role": "user", "content": "My name is Sam."},
                     {"role": "assistant", "content": "Hi Sam."},
                     {"role": "user", "content": "What is my name? One word."}]}, timeout=120)
    if "choices" in d:
        r["turn2"] = {"latency_s": round(lat, 2),
                      "content": (d["choices"][0]["message"].get("content") or "")[:80]}
    else:
        r["turn2"] = {"error": d}
    return r

def run_one(m, operator_port, scratch_port):
    res = {"alias": m["alias"], "dir": m["dir"], "role": m["role"],
           "tool_parser": m["tool_parser"], "reasoning_parser": m.get("reasoning_parser")}
    mdir = f"{MODELS_DIR}/{m['dir']}"
    if not os.path.isdir(mdir):
        res["status"] = "MISSING_ON_DISK"; return res
    # reuse operator if it's the one already up on operator_port
    op_ids = models_up(operator_port)
    reuse = op_ids and (m["alias"] in op_ids)
    if reuse:
        res["status"] = "reused_operator_port"; res["port"] = operator_port
        res["mem_free_gb_before"] = round(free_ram_gb(), 1)
        res.update(probe_model(m["alias"], operator_port, m["alias"]))
        return res
    # memory preflight
    size = dir_size_gb(mdir)
    free = free_ram_gb()
    res["size_gb"] = round(size, 1); res["mem_free_gb_before"] = round(free, 1)
    if free >= 0 and free < size + HEADROOM_GB:
        res["status"] = f"SKIPPED_low_memory (free {free:.0f}G < need {size + HEADROOM_GB:.0f}G)"
        return res
    kill_port(scratch_port); time.sleep(1)
    t0 = now()
    try:
        if m["serve"] == "mlx_lm":
            p, logf = launch_mlx_lm(m, scratch_port)
            expect_id = mdir
        else:
            p, logf = launch_vllm(m, scratch_port)
            expect_id = m["alias"]
        ids = wait_ready(scratch_port, READY_TIMEOUT, logf)
        res["load_time_s"] = round(now() - t0, 1)
        if not ids:
            res["status"] = "FAILED_to_start"
            try: res["log_tail"] = open(logf).read()[-600:]
            except Exception: pass
            kill_port(scratch_port); return res
        res["status"] = "tested"; res["port"] = scratch_port; res["served_ids"] = ids
        model_id = expect_id if expect_id in ids else ids[0]
        res.update(probe_model(m["alias"], scratch_port, model_id,
                               is_reasoner=bool(m.get("reasoning_parser"))))
    finally:
        kill_port(scratch_port); time.sleep(2)
    return res

def verdict(res):
    """One-line human verdict from the probe results."""
    if res.get("status", "").startswith(("SKIPPED", "MISSING", "FAILED")):
        return res["status"]
    tc = res.get("tool_call", {})
    tv = "tools:OK" if tc.get("structured_tool_call") and tc.get("args_valid_json") else \
         ("tools:NONE" if tc.get("structured_tool_call") is False else "tools:?")
    hv = res.get("hello", {})
    hl = f'{hv.get("latency_s","?")}s/{hv.get("out_tokens","?")}tok' if "latency_s" in hv else "hello:err"
    sv = "stream:OK" if res.get("streaming", {}).get("ok") else "stream:?"
    return f'{tv}  {hl}  {sv}  load {res.get("load_time_s","reuse")}s'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="alias to run alone")
    ap.add_argument("--include-large", action="store_true", help="also run >%.0fG models (supervised)" % LARGE_GB)
    ap.add_argument("--operator-port", type=int, default=8000)
    ap.add_argument("--scratch-port", type=int, default=8001)
    a = ap.parse_args()

    outdir = f"{HOME}/.claude/logs/tournament-{utcstamp()}"
    os.makedirs(outdir, exist_ok=True)
    sel = [m for m in MODELS if (not a.only or m["alias"] == a.only)]
    if not a.include_large:
        sel = [m for m in sel if not m.get("large")]

    print(f"# Tournament (Stage A) — {datetime.now(timezone.utc).isoformat()}")
    print(f"  operator-port={a.operator_port} scratch-port={a.scratch_port} "
          f"large={'included' if a.include_large else 'skipped'}  free RAM {free_ram_gb():.0f}G")
    results = []
    for m in sel:
        print(f"\n--- {m['alias']} ({m['role']}) ---", flush=True)
        r = run_one(m, a.operator_port, a.scratch_port)
        r["verdict"] = verdict(r)
        print(f"  => {r['verdict']}", flush=True)
        results.append(r)
        json.dump(results, open(f"{outdir}/results.json", "w"), indent=2)

    # markdown summary
    with open(f"{outdir}/results.md", "w") as f:
        f.write(f"# Local model tournament — Stage A ({utcstamp()} UTC)\n\n")
        f.write("| alias | role | verdict |\n|---|---|---|\n")
        for r in results:
            f.write(f"| {r['alias']} | {r['role']} | {r['verdict']} |\n")
        f.write("\n## Full probe detail\n```json\n")
        f.write(json.dumps(results, indent=2))
        f.write("\n```\n")
    print(f"\nResults: {outdir}/results.{{json,md}}")

if __name__ == "__main__":
    main()
