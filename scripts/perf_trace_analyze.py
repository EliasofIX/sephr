#!/usr/bin/env python3
"""Summarize a Chromium trace: who produces frames and why.
Usage: perf_trace_analyze.py /tmp/sephr-trace.json"""
import json, sys, collections

data = json.load(open(sys.argv[1]))
events = data["traceEvents"] if isinstance(data, dict) else data
names = collections.Counter()
durs = collections.defaultdict(float)
for e in events:
    n = e.get("name", "?")
    names[n] += 1
    durs[n] += e.get("dur", 0) / 1000.0  # ms

print("== top by count ==")
for n, c in names.most_common(25):
    print(f"{c:8d}  {durs[n]:10.1f}ms  {n}")

interesting = ["BeginFrame", "Scheduler::BeginFrame", "Commit",
               "UpdateLayoutTree", "LocalFrameView::RunStyleAndLayoutLifecyclePhases",
               "Paint", "ProxyMain::BeginMainFrame", "Graphics.Pipeline",
               "NeedsBeginFrameChanged", "SetNeedsRedraw",
               "WebContentsImpl::UpdateWebContentsVisibility"]
print("\n== frame-pipeline signals ==")
for key in interesting:
    hits = [(n, c) for n, c in names.items() if key.lower() in n.lower()]
    for n, c in hits:
        print(f"{c:8d}  {n}")
