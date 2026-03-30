#!/usr/bin/env python3
"""
Evaluate experiment results from a Polygon POS node autoresearch run.

Usage:
    python3 evaluate.py <experiment_dir>
    python3 evaluate.py --compare <dir1> <dir2>
    python3 evaluate.py --latest
"""

import csv
import json
import os
import re
import sys
from pathlib import Path
from statistics import mean, median, stdev


PROJECT_DIR = Path(__file__).parent.parent
RESULTS_DIR = PROJECT_DIR / "results"


def load_metrics(experiment_dir: Path) -> list[dict]:
    """Load metrics CSV from an experiment directory."""
    metrics_file = experiment_dir / "metrics.csv"
    if not metrics_file.exists():
        print(f"WARNING: No metrics.csv found in {experiment_dir}")
        return []

    rows = []
    with open(metrics_file) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "timestamp": int(row["timestamp"]),
                "cpu_percent": float(row["cpu_percent"]),
                "memory_mb": int(row["memory_mb"]),
                "disk_read_mb": int(row["disk_read_mb"]),
                "disk_write_mb": int(row["disk_write_mb"]),
                "peers": int(row["peers"]),
            })
    return rows


def load_debug_metrics(experiment_dir: Path) -> dict:
    """Load debug metrics JSON if available."""
    metrics_file = experiment_dir / "debug_metrics.json"
    if not metrics_file.exists():
        return {}
    try:
        with open(metrics_file) as f:
            data = json.load(f)
            return data.get("result", {})
    except (json.JSONDecodeError, KeyError):
        return {}


def load_final_state(experiment_dir: Path) -> dict:
    """Load final state info."""
    state_file = experiment_dir / "final_state.txt"
    if not state_file.exists():
        return {}

    state = {}
    with open(state_file) as f:
        for line in f:
            if "=" in line:
                key, val = line.strip().split("=", 1)
                state[key] = val
    return state


def parse_block_import_times(experiment_dir: Path) -> list[float]:
    """Parse block import times from node logs."""
    log_file = experiment_dir / "node.log"
    if not log_file.exists():
        return []

    times = []
    # Bor logs block imports with timing info
    # Pattern: "Imported new chain segment" ... "elapsed=XXms"
    pattern = re.compile(r"elapsed[=:](\d+(?:\.\d+)?)(ms|s|us)")

    with open(log_file) as f:
        for line in f:
            if "import" in line.lower() or "block" in line.lower():
                match = pattern.search(line)
                if match:
                    value = float(match.group(1))
                    unit = match.group(2)
                    if unit == "s":
                        value *= 1000
                    elif unit == "us":
                        value /= 1000
                    times.append(value)  # normalize to ms

    return times


def evaluate(experiment_dir: Path) -> dict:
    """Evaluate a single experiment and return a results dict."""
    metrics = load_metrics(experiment_dir)
    debug_metrics = load_debug_metrics(experiment_dir)
    final_state = load_final_state(experiment_dir)
    block_times = parse_block_import_times(experiment_dir)

    results = {
        "experiment": experiment_dir.name,
        "path": str(experiment_dir),
    }

    # Process time-series metrics
    if metrics:
        cpu_values = [m["cpu_percent"] for m in metrics]
        mem_values = [m["memory_mb"] for m in metrics]

        results["cpu"] = {
            "mean": round(mean(cpu_values), 2),
            "max": round(max(cpu_values), 2),
            "median": round(median(cpu_values), 2),
        }
        results["memory_mb"] = {
            "mean": round(mean(mem_values)),
            "max": max(mem_values),
            "median": round(median(mem_values)),
        }

        # Disk I/O (total over experiment)
        if len(metrics) >= 2:
            total_read = metrics[-1]["disk_read_mb"] - metrics[0]["disk_read_mb"]
            total_write = metrics[-1]["disk_write_mb"] - metrics[0]["disk_write_mb"]
            duration = metrics[-1]["timestamp"] - metrics[0]["timestamp"]
            results["disk_io"] = {
                "total_read_mb": total_read,
                "total_write_mb": total_write,
                "read_mb_per_sec": round(total_read / max(duration, 1), 2),
                "write_mb_per_sec": round(total_write / max(duration, 1), 2),
            }

    # Block processing
    if block_times:
        results["block_processing_ms"] = {
            "mean": round(mean(block_times), 2),
            "median": round(median(block_times), 2),
            "min": round(min(block_times), 2),
            "max": round(max(block_times), 2),
            "stdev": round(stdev(block_times), 2) if len(block_times) > 1 else 0,
            "count": len(block_times),
        }

    # Final state
    if "final_block" in final_state:
        results["final_block"] = int(final_state["final_block"])

    # Bor-specific debug metrics
    if debug_metrics:
        results["debug_metrics_available"] = True
        # Extract chain-related metrics if present
        for key in ["chain/inserts", "chain/execution", "chain/validation",
                     "state/commit", "trie/memcache/gc"]:
            if key in debug_metrics:
                results[key.replace("/", "_")] = debug_metrics[key]

    return results


def print_results(results: dict):
    """Pretty print experiment results."""
    print(f"\n{'='*60}")
    print(f" Experiment: {results['experiment']}")
    print(f"{'='*60}")

    if "cpu" in results:
        cpu = results["cpu"]
        print(f"\n  CPU Usage:")
        print(f"    Mean: {cpu['mean']}%  |  Max: {cpu['max']}%  |  Median: {cpu['median']}%")

    if "memory_mb" in results:
        mem = results["memory_mb"]
        print(f"\n  Memory Usage:")
        print(f"    Mean: {mem['mean']} MB  |  Max: {mem['max']} MB  |  Median: {mem['median']} MB")

    if "disk_io" in results:
        dio = results["disk_io"]
        print(f"\n  Disk I/O:")
        print(f"    Read: {dio['total_read_mb']} MB ({dio['read_mb_per_sec']} MB/s)")
        print(f"    Write: {dio['total_write_mb']} MB ({dio['write_mb_per_sec']} MB/s)")

    if "block_processing_ms" in results:
        bp = results["block_processing_ms"]
        print(f"\n  Block Processing ({bp['count']} blocks):")
        print(f"    Mean: {bp['mean']} ms  |  Median: {bp['median']} ms")
        print(f"    Min: {bp['min']} ms  |  Max: {bp['max']} ms  |  Stdev: {bp['stdev']} ms")

    if "final_block" in results:
        print(f"\n  Final Block: {results['final_block']}")

    print(f"\n{'='*60}\n")


def compare(dir1: Path, dir2: Path):
    """Compare two experiments side by side."""
    r1 = evaluate(dir1)
    r2 = evaluate(dir2)

    print(f"\n{'='*70}")
    print(f" Comparison: {r1['experiment']} vs {r2['experiment']}")
    print(f"{'='*70}")

    def compare_metric(name, key, subkey, lower_is_better=True):
        v1 = r1.get(key, {}).get(subkey)
        v2 = r2.get(key, {}).get(subkey)
        if v1 is None or v2 is None:
            return
        diff = v2 - v1
        pct = (diff / v1 * 100) if v1 != 0 else 0
        better = (diff < 0) if lower_is_better else (diff > 0)
        arrow = "v" if better else "^" if not better else "="
        indicator = "BETTER" if better else "WORSE" if diff != 0 else "SAME"
        print(f"  {name:30s}  {v1:>10}  {v2:>10}  {diff:>+10.1f} ({pct:>+.1f}%) [{indicator}]")

    print(f"\n  {'Metric':30s}  {'Exp 1':>10}  {'Exp 2':>10}  {'Delta':>10}")
    print(f"  {'-'*30}  {'-'*10}  {'-'*10}  {'-'*10}")

    compare_metric("CPU Mean (%)", "cpu", "mean", lower_is_better=True)
    compare_metric("CPU Max (%)", "cpu", "max", lower_is_better=True)
    compare_metric("Memory Mean (MB)", "memory_mb", "mean", lower_is_better=True)
    compare_metric("Memory Max (MB)", "memory_mb", "max", lower_is_better=True)
    compare_metric("Block Proc Mean (ms)", "block_processing_ms", "mean", lower_is_better=True)
    compare_metric("Block Proc Median (ms)", "block_processing_ms", "median", lower_is_better=True)
    compare_metric("Disk Read (MB/s)", "disk_io", "read_mb_per_sec", lower_is_better=True)
    compare_metric("Disk Write (MB/s)", "disk_io", "write_mb_per_sec", lower_is_better=True)

    print()


def find_latest() -> Path | None:
    """Find the latest experiment directory."""
    if not RESULTS_DIR.exists():
        return None
    dirs = sorted([d for d in RESULTS_DIR.iterdir() if d.is_dir()])
    return dirs[-1] if dirs else None


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 evaluate.py <experiment_dir>")
        print("  python3 evaluate.py --compare <dir1> <dir2>")
        print("  python3 evaluate.py --latest")
        print("  python3 evaluate.py --all")
        sys.exit(1)

    if sys.argv[1] == "--latest":
        latest = find_latest()
        if latest is None:
            print("No experiments found.")
            sys.exit(1)
        results = evaluate(latest)
        print_results(results)

    elif sys.argv[1] == "--compare":
        if len(sys.argv) < 4:
            print("Usage: python3 evaluate.py --compare <dir1> <dir2>")
            sys.exit(1)
        compare(Path(sys.argv[2]), Path(sys.argv[3]))

    elif sys.argv[1] == "--all":
        if not RESULTS_DIR.exists():
            print("No results directory found.")
            sys.exit(1)
        for d in sorted(RESULTS_DIR.iterdir()):
            if d.is_dir() and d.name != ".gitkeep":
                results = evaluate(d)
                print_results(results)

    else:
        experiment_dir = Path(sys.argv[1])
        if not experiment_dir.exists():
            print(f"ERROR: Directory not found: {experiment_dir}")
            sys.exit(1)
        results = evaluate(experiment_dir)
        print_results(results)

    # Save results as JSON for programmatic access
    output_json = RESULTS_DIR / "latest_evaluation.json"
    if "results" in dir():
        with open(output_json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"Results saved to: {output_json}")


if __name__ == "__main__":
    main()
