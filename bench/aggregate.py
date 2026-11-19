#!/usr/bin/env python3
"""Aggregate raw.jsonl into results.json and a markdown table."""
import json, statistics, subprocess, platform, datetime, collections

rows = [json.loads(l) for l in open("raw.jsonl")]
data = collections.defaultdict(lambda: collections.defaultdict(list))
sums = collections.defaultdict(lambda: collections.defaultdict(set))
for r in rows:
    if r["round"] == 0:  # warmup
        continue
    data[r["w"]][r["driver"]].append(r["ms"])
    sums[r["w"]][r["driver"]].add(r["sum"])

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

meta = {
    "date": datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC"),
    "reps": len(next(iter(data.values()))["mjollnir"]),
    "cpu": sh("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2").strip(),
    "cores": int(sh("nproc")),
    "mem_mb": int(sh("free -m | awk '/Mem:/{print $2}'")),
    "os": sh("grep PRETTY_NAME /etc/os-release | cut -d= -f2").strip('"'),
    "kernel": platform.release(),
    "crystal": sh("crystal --version | head -1"),
    "postgres": sh("PGPASSWORD=mjol psql -h 127.0.0.1 -U mjol -d mjol -Atc 'select version()'").split(",")[0],
}

order = []
for r in rows:
    if r["w"] not in order and not r["w"].startswith("_"):
        order.append(r["w"])

out = {"meta": meta, "results": {}}
lines = ["| workload | Mjollnir (ms) | crystal-pg (ms) | speedup | checksum |",
         "|---|---:|---:|---:|:---:|"]
for w in order:
    entry = {}
    for d in ("mjollnir", "pg"):
        t = data[w][d]
        entry[d] = {"median_ms": statistics.median(t), "min_ms": min(t), "max_ms": max(t),
                    "stdev_ms": statistics.stdev(t) if len(t) > 1 else 0.0, "times_ms": t}
    ok = len(sums[w]["mjollnir"] | sums[w]["pg"]) == 1
    entry["checksum_match"] = ok
    entry["speedup"] = entry["pg"]["median_ms"] / entry["mjollnir"]["median_ms"]
    out["results"][w] = entry
    lines.append(f"| {w} | {entry['mjollnir']['median_ms']:.1f} | {entry['pg']['median_ms']:.1f} | "
                 f"{entry['speedup']:.2f}x | {'ok' if ok else 'MISMATCH'} |")

rss = {d: statistics.median([r["sum"] for r in rows if r["w"] == "_peak_rss_kb" and r["driver"] == d and r["round"] > 0]) / 1024
       for d in ("mjollnir", "pg")}
out["peak_rss_mb"] = rss
json.dump(out, open("results.json", "w"), indent=1)
open("results.md", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
print(f"\npeak RSS (whole run, median): Mjollnir {rss['mjollnir']:.1f} MB, crystal-pg {rss['pg']:.1f} MB")
