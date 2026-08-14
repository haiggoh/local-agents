#!/usr/bin/env python3
"""Simple local proxy translating minimal OpenAI-style requests to local-agent-dispatch.

Usage: copilot_local_proxy.py --port 8081

Endpoints:
  GET  /v1/models                 -> forwards to local hotswap /v1/models
  POST /v1/chat/completions       -> expects JSON {"model": "alias", "messages": [...]}

This is a small proof-of-concept not for production. It calls the existing local-llm-hotswap.sh
and local-agent-dispatch.py in the same bin directory.
"""

import argparse
import json
import subprocess
import shlex
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
HOTSWAP = os.path.join(BIN_DIR, "local-llm-hotswap.sh")
DISPATCH = os.path.join(BIN_DIR, "local-agent-dispatch.py")
LOG_DIR = os.path.abspath(os.path.join(BIN_DIR, '..', 'logs'))
os.makedirs(LOG_DIR, exist_ok=True)
PROXY_LOG_PATH = os.path.join(LOG_DIR, 'proxy_requests.log')


def _append_proxy_log(entry: str):
    try:
        with open(PROXY_LOG_PATH, 'a', encoding='utf-8') as f:
            f.write(entry + "\n")
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "CopilotLocalProxy/0.1"
    protocol_version = "HTTP/1.1"

    def _send_json(self, obj, code=200):
        data = json.dumps(obj)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data.encode('utf-8'))))
        # prefer persistent connection for client probes
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(data.encode('utf-8'))

    def do_GET(self):
        # Log incoming request for debugging
        try:
            headers = {k: v for k, v in self.headers.items()}
        except Exception:
            headers = {}
        print(f"[proxy-access] {self.command} {self.path} headers={headers}")
        try:
            _append_proxy_log(f"[REQ] {self.command} {self.path} headers={headers}")
        except Exception:
            pass
        p = urlparse(self.path)
        path = p.path
        # Normalize both /v1/models and /models (some clients append base paths differently)
        # /v1/models or /models -> return the provider model list (hotswap first)
        if path in ("/v1/models", "/models"):
            q = dict([kv.split('=') for kv in p.query.split('&') if kv]) if p.query else {}
            alias = q.get('model', 'qwen-3.6-operator')
            try:
                res = subprocess.run([HOTSWAP, alias], capture_output=True, text=True, check=False)
                out = res.stdout + "\n" + res.stderr
                import re
                m = re.search(r"SUCCESS_PORT=(\d+)", out)
                port = int(m.group(1)) if m else 8000
                curl = ["curl", "-sS", f"http://localhost:{port}/v1/models"]
                c = subprocess.run(curl, capture_output=True, text=True)
                if c.returncode == 0:
                    try:
                        obj = json.loads(c.stdout)
                    except Exception:
                        obj = {"object":"list","data":[]}
                    self._send_json(obj)
                    return
                else:
                    self._send_json({"error":"failed to query local model server"}, 502)
                    return
            except FileNotFoundError:
                self._send_json({"error":"hotswap script missing"}, 500)
                return

        # /v1/models/<id> or /models/<id> -> return a single model object
        if path.startswith("/v1/models/") or path.startswith("/models/"):
            model_id = path.split('/')[-1]

            # Support HEAD/OPTIONS which some clients use to probe model existence
            if self.command in ("HEAD", "OPTIONS"):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                return

            try:
                res = subprocess.run([HOTSWAP, model_id], capture_output=True, text=True, check=False)
                out = res.stdout + "\n" + res.stderr
                import re
                m = re.search(r"SUCCESS_PORT=(\d+)", out)
                port = int(m.group(1)) if m else 8000
                curl = ["curl", "-sS", f"http://localhost:{port}/v1/models"]
                c = subprocess.run(curl, capture_output=True, text=True)
                if c.returncode == 0:
                    try:
                        obj = json.loads(c.stdout)
                        for item in obj.get('data', []):
                            if item.get('id') == model_id:
                                self._send_json(item)
                                return
                    except Exception:
                        pass
                    # If not found, respond optimistically with a minimal descriptor
                    model_obj = {"id": model_id, "object": "model", "owned_by": "vllm-mlx"}
                    self._send_json(model_obj)
                    return
                else:
                    self._send_json({"error":"failed to query local model server"}, 502)
                    return
            except FileNotFoundError:
                self._send_json({"error":"hotswap script missing"}, 500)
                return

        # Additional helper path: /v1/models/<id>/versions -> return a small versions list
        if path.startswith("/v1/models/") and path.endswith("/versions"):
            model_id = path.split('/')[-2]
            versions = {"object": "list", "data": [{"id": model_id, "object": "model_version", "owned_by": "vllm-mlx"}]}
            self._send_json(versions)
            return

        # Health check
        if path == "/.well-known/ai-plugin.json" or path == "/health" or path == "/.well-known/ai-plugin":
            self._send_json({"status": "ok"})
            return

        # Fallback: be permissive and return a fuller OpenAI-style models list/object for probes
        print(f"[proxy-access] FALLBACK responding 200 for GET {path}")
        import time, uuid
        now = int(time.time())
        def model_obj_for(id_):
            return {
                "id": id_,
                "object": "model",
                "created": now,
                "owned_by": "vllm-mlx",
                "root": id_,
                "name": id_,
                "capabilities": {
                    "supports": {"vision": False, "adaptive_thinking": "unsupported"},
                    "limits": {
                        "max_prompt_tokens": 128000,
                        "max_context_window_tokens": 200000
                    }
                },
                "permission": [
                    {
                        "id": str(uuid.uuid4()),
                        "object": "model_permission",
                        "allow_create_engine": False,
                        "allow_sampling": True,
                        "allow_logprobs": True,
                        "allow_search_indices": False,
                        "allow_view": True,
                        "allow_fine_tuning": False,
                        "status": "active"
                    }
                ]
            }
        # If the request looks like a single model query, return the model object
        if path.startswith('/v1/models/') or path.startswith('/models/'):
            model_id = path.split('/')[-1]
            self._send_json(model_obj_for(model_id))
            return
        # Otherwise, return a model list that includes the common qwen alias
        model_list = {"object": "list", "data": [model_obj_for("qwen-3.6-operator")], "meta": {"total_count": 1}}
        self._send_json(model_list)
        return

        self.send_error(404)

    def do_HEAD(self):
        # Log HEAD requests for debugging and delegate to GET handler for probe emulation
        try:
            headers = {k: v for k, v in self.headers.items()}
        except Exception:
            headers = {}
        print(f"[proxy-access] {self.command} {self.path} headers={headers}")
        try:
            _append_proxy_log(f"[REQ] {self.command} {self.path} headers={headers}")
        except Exception:
            pass
        # For probes, emulate GET handling (may return headers/body) — acceptable for debugging
        return self.do_GET()

    def do_OPTIONS(self):
        # Respond permissively to OPTIONS used by some clients
        try:
            headers = {k: v for k, v in self.headers.items()}
        except Exception:
            headers = {}
        print(f"[proxy-access] {self.command} {self.path} headers={headers}")
        try:
            _append_proxy_log(f"[REQ] {self.command} {self.path} headers={headers}")
        except Exception:
            pass
        self.send_response(200)
        self.send_header('Allow', 'GET,HEAD,POST,OPTIONS')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_POST(self):
        # Log incoming request for debugging
        try:
            headers = {k: v for k, v in self.headers.items()}
        except Exception:
            headers = {}
        print(f"[proxy-access] {self.command} {self.path} headers={headers}")
        try:
            _append_proxy_log(f"[REQ] {self.command} {self.path} headers={headers}")
        except Exception:
            pass
        p = urlparse(self.path)
        if p.path in ("/v1/chat/completions", "/v1/completions", "/chat/completions", "/completions", "/v1/complete", "/complete"):
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8') if length else ''
            try:
                payload = json.loads(body) if body else {}
            except Exception:
                self._send_json({"error":"invalid json"}, 400); return

            model_alias = payload.get('model') or payload.get('model_alias') or 'qwen-3.6-operator'
            messages = payload.get('messages') or []
            # Convert messages to a single prompt string: simple concatenation
            prompt_parts = []
            for m in messages:
                role = m.get('role','user')
                content = m.get('content','')
                prompt_parts.append(f"{role.capitalize()}: {content}")
            prompt = "\n".join(prompt_parts).strip()
            if not prompt:
                self._send_json({"error":"empty messages/prompt"}, 400); return

            # Ensure server is up and get port via hotswap
            try:
                hs = subprocess.run([HOTSWAP, model_alias], capture_output=True, text=True, check=False)
                out = hs.stdout + "\n" + hs.stderr
                import re
                m = re.search(r"SUCCESS_PORT=(\d+)", out)
                if m:
                    port = int(m.group(1))
                else:
                    port = 8000
            except FileNotFoundError:
                self._send_json({"error":"hotswap script missing"}, 500); return

            # Use the dispatcher to run the prompt — it will call the server's /v1/chat/completions
            try:
                cmd = ["python3", DISPATCH, "--model", model_alias, "--prompt", prompt, "--max-tokens", "1024"]
                proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
                out_text = proc.stdout.strip()
                
                # Check if client expects streaming (x-stainless-helper-method: stream)
                wants_stream = headers.get('x-stainless-helper-method', '').lower() == 'stream'
                
                if wants_stream:
                    # Send as Server-Sent Events (SSE) streaming format
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Connection", "keep-alive")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    
                    # Send response chunks as SSE events
                    # First: chunk event with the full response
                    chunk_data = {
                        "id": "chatcmpl-1",
                        "object": "chat.completion.chunk",
                        "created": int(time.time()),
                        "model": model_alias,
                        "choices": [{"index": 0, "delta": {"role": "assistant", "content": out_text}, "finish_reason": None}]
                    }
                    sse_msg = f"data: {json.dumps(chunk_data)}\n\n".encode('utf-8')
                    sse_chunk = format(len(sse_msg), 'x').encode('utf-8') + b"\r\n" + sse_msg + b"\r\n"
                    self.wfile.write(sse_chunk)
                    
                    # Final: stop event
                    stop_data = {
                        "id": "chatcmpl-1",
                        "object": "chat.completion.chunk",
                        "created": int(time.time()),
                        "model": model_alias,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]
                    }
                    sse_stop = f"data: {json.dumps(stop_data)}\n\n".encode('utf-8')
                    sse_stop_chunk = format(len(sse_stop), 'x').encode('utf-8') + b"\r\n" + sse_stop + b"\r\n"
                    self.wfile.write(sse_stop_chunk)
                    
                    # Terminate chunked encoding
                    self.wfile.write(b"0\r\n\r\n")
                    return
                else:
                    # Non-streaming response
                    choice = {
                        "message": {"role": "assistant", "content": out_text},
                        "finish_reason": "stop"
                    }
                    resp = {
                        "id": "localcmpl-1",
                        "object": "chat.completion",
                        "choices": [choice],
                        "usage": {"prompt_tokens": 0, "completion_tokens": len(out_text.split()), "total_tokens": len(out_text.split())}
                    }
                    self._send_json(resp)
                    return
            except Exception as e:
                self._send_json({"error": f"dispatch failed: {e}"}, 500); return
        self.send_error(404)

    def log_message(self, format, *args):
        # shrink noisy logs
        print("[proxy] " + format % args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8081)
    parser.add_argument('--host', default='127.0.0.1')
    args = parser.parse_args()

    server = HTTPServer((args.host, args.port), Handler)
    print(f"Copilot Local Proxy listening on http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('shutting down')
        server.server_close()

if __name__ == '__main__':
    main()
