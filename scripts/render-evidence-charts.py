#!/usr/bin/env python3
"""Render article figures from Cloud Monitoring (Google Managed Prometheus) for a time window.

Each figure states its metric type, aggregation, and window in its title, so a reader can re-run the query.
Usage: render-evidence-charts.py <start-iso> <end-iso> <out-dir>
Reads the access token from `gcloud auth print-access-token` (never printed).
"""
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

PROJECT = "llm-k8s-experimental"
API = f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries"

SERIES = [
    # (metric type, aligner, reducer, label)
    ("prometheus.googleapis.com/llamacpp:tokens_predicted_total/counter", "ALIGN_RATE", "REDUCE_SUM", "generated tokens/s"),
    ("prometheus.googleapis.com/llamacpp:prompt_tokens_total/counter", "ALIGN_RATE", "REDUCE_SUM", "prompt tokens/s"),
    ("prometheus.googleapis.com/llamacpp:requests_processing/gauge", "ALIGN_MEAN", "REDUCE_SUM", "requests in flight"),
    ("prometheus.googleapis.com/llamacpp:requests_deferred/gauge", "ALIGN_MEAN", "REDUCE_SUM", "requests deferred"),
]


def token() -> str:
    return subprocess.run(
        ["gcloud", "auth", "print-access-token"], capture_output=True, text=True, check=True
    ).stdout.strip()


def query(metric: str, aligner: str, reducer: str, start: str, end: str, tok: str):
    params = {
        "filter": f'metric.type="{metric}"',
        "interval.startTime": start,
        "interval.endTime": end,
        "aggregation.alignmentPeriod": "30s",
        "aggregation.perSeriesAligner": aligner,
        "aggregation.crossSeriesReducer": reducer,
    }
    req = urllib.request.Request(
        f"{API}?{urllib.parse.urlencode(params)}",
        headers={"Authorization": f"Bearer {tok}", "x-goog-user-project": PROJECT},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    points = []
    for ts in data.get("timeSeries", []):
        for p in ts.get("points", []):
            t = datetime.fromisoformat(p["interval"]["endTime"].replace("Z", "+00:00"))
            v = p["value"].get("doubleValue", p["value"].get("int64Value", 0))
            points.append((t, float(v)))
    points.sort()
    return points


def main() -> None:
    start, end, out = sys.argv[1], sys.argv[2], sys.argv[3]
    tok = token()
    fig, axes = plt.subplots(len(SERIES), 1, figsize=(10, 9), sharex=True)
    for ax, (metric, aligner, reducer, label) in zip(axes, SERIES):
        pts = query(metric, aligner, reducer, start, end, tok)
        xs = [p[0] for p in pts]
        ys = [float(p[1]) for p in pts]
        ax.plot(xs, ys, linewidth=1.6)
        ax.set_ylabel(label, fontsize=9)
        ax.grid(alpha=0.3)
        print(f"{label}: {len(pts)} points, max={max(ys) if ys else 0:.2f}")
    axes[0].set_title(
        f"llama-server during the load test ({start} to {end} UTC)\n"
        "Source: Cloud Monitoring, prometheus.googleapis.com/llamacpp:*, 30 s alignment, summed over replicas",
        fontsize=10,
    )
    axes[-1].set_xlabel("time (UTC)")
    fig.tight_layout()
    path = f"{out}/load-window-llamacpp.png"
    fig.savefig(path, dpi=150)
    print("wrote", path)


if __name__ == "__main__":
    main()
