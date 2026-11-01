#!/usr/bin/env python3
"""True time to first token for the llama.cpp endpoint.

Why this exists: k6 buffers the response, so its `http_req_waiting` is time to the first byte of the
SSE stream, which llama-server flushes before it has generated anything. This client reads the first
`data:` line of the stream and timestamps it, which is the number a user actually feels.

It runs with the standard library only, so it can be piped into the model pod (which ships python3)
and measure from inside the serving namespace: no new image, no new ServiceAccount, no network noise
between the client and the server.

  kubectl -n llm-serving exec -i deploy/model-endpoint -- python3 - < load/ttft-stream.py
  (load/run-ttft.sh does exactly that and stores the output as evidence)

Output is a table per concurrency level: requests, errors, TTFT p50/p95/max, full-stream p50/p95,
and output chunks per second.
"""
import argparse
import http.client
import json
import statistics
import threading
import time

PROMPT = "Describe the sea in one short sentence."


def one_request(host, port, key, model, max_tokens):
    """One streamed chat completion. Returns (ttft_ms, total_ms, chunks)."""
    body = json.dumps(
        {
            "model": model,
            "stream": True,
            "max_tokens": max_tokens,
            "temperature": 0,
            "messages": [{"role": "user", "content": PROMPT}],
        }
    )
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    conn = http.client.HTTPConnection(host, port, timeout=300)
    started = time.perf_counter()
    try:
        conn.request("POST", "/v1/chat/completions", body=body, headers=headers)
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"status {resp.status}")
        ttft = None
        chunks = 0
        while True:
            line = resp.readline()
            if not line:
                break
            if line.startswith(b"data: "):
                chunks += 1
                # The first data line is the first token (or the role delta), so the timestamp here
                # is an upper bound on true first-token latency and a lower bound is the header time.
                if ttft is None:
                    ttft = (time.perf_counter() - started) * 1000
        total = (time.perf_counter() - started) * 1000
        if ttft is None:
            raise RuntimeError("stream produced no data")
        return ttft, total, chunks
    finally:
        conn.close()


def pct(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((p / 100) * (len(ordered) - 1))))
    return ordered[idx]


def run_level(level, seconds, host, port, key, model, max_tokens):
    deadline = time.perf_counter() + seconds
    lock = threading.Lock()
    ttfts, totals, chunks, errors = [], [], [], []

    def worker():
        while time.perf_counter() < deadline:
            try:
                t, total, n = one_request(host, port, key, model, max_tokens)
                with lock:
                    ttfts.append(t)
                    totals.append(total)
                    chunks.append(n)
            except Exception as exc:  # noqa: BLE001 - the harness reports every failure, not a trace
                with lock:
                    errors.append(str(exc))
            time.sleep(1)

    threads = [threading.Thread(target=worker) for _ in range(level)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = seconds
    return {
        "users": level,
        "requests": len(ttfts),
        "errors": len(errors),
        "ttft_p50": pct(ttfts, 50),
        "ttft_p95": pct(ttfts, 95),
        "ttft_max": max(ttfts) if ttfts else 0,
        "total_p50": pct(totals, 50),
        "total_p95": pct(totals, 95),
        "chunks_per_s": sum(chunks) / wall if chunks else 0,
        "first_error": errors[0] if errors else "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--key-file", default="/etc/llm/api-keys/api-keys")
    ap.add_argument("--model", default="qwen2.5-0.5b-instruct")
    ap.add_argument("--levels", default="1,2,4,6,8")
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--max-tokens", type=int, default=48)
    args = ap.parse_args()

    with open(args.key_file) as fh:
        key = fh.readline().strip()

    levels = [int(x) for x in args.levels.split(",")]
    print(f"# true TTFT, {args.model}, {args.seconds}s per level, max_tokens={args.max_tokens}")
    print(f"# client: python3 inside the serving pod, loopback to {args.host}:{args.port}")
    print()
    print("users | req | err | ttft p50 (ms) | ttft p95 (ms) | ttft max (ms) | stream p50 (ms) | stream p95 (ms) | chunks/s")
    print("------+-----+-----+---------------+---------------+---------------+-----------------+-----------------+---------")
    for level in levels:
        r = run_level(level, args.seconds, args.host, args.port, key, args.model, args.max_tokens)
        print(
            f"{r['users']:5d} | {r['requests']:3d} | {r['errors']:3d} | "
            f"{r['ttft_p50']:13.1f} | {r['ttft_p95']:13.1f} | {r['ttft_max']:13.1f} | "
            f"{r['total_p50']:15.1f} | {r['total_p95']:15.1f} | {r['chunks_per_s']:8.2f}"
        )
        if r["first_error"]:
            print(f"        first error: {r['first_error']}")
    print()
    print("# ttft is the first 'data:' line of the stream, not the response headers.")


if __name__ == "__main__":
    main()
