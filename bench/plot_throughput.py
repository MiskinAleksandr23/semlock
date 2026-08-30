#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "matplotlib>=3.10,<4",
# ]
# ///

import csv
import json
import math
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.ticker import LogFormatterMathtext, LogLocator, NullFormatter


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV = ROOT / "bench" / "results" / "sweep.csv"
VERSIONS = (
    ("v1", "V1", "#4C78A8", "o"),
    ("v1-long-adder", "V1 + LongAdder", "#B279A2", "D"),
    ("v2", "V2", "#F58518", "s"),
    ("no-lock", "No lock", "#54A24B", "^"),
)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def load_rows(path: Path) -> list[dict]:
    rows = []
    with path.open(newline="", encoding="utf-8") as csv_file:
        for raw in csv.DictReader(csv_file):
            try:
                items_per_run = int(raw["items_per_run"])
                timings = [int(value) for value in json.loads(raw["timings_ns"])]
                sample_throughput = [
                    items_per_run * 1_000_000_000.0 / timing for timing in timings
                ]
                rows.append(
                    {
                        "version": raw["version"],
                        "threads": int(raw["threads"]),
                        "workload": raw["workload"],
                        "throughput": percentile(sample_throughput, 0.50),
                        "q25": percentile(sample_throughput, 0.25),
                        "q75": percentile(sample_throughput, 0.75),
                    }
                )
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                continue
    return rows


def workload_code(workload: str) -> str:
    match = re.match(r"\(([a-zA-Z])\)", workload)
    return match.group(1).lower() if match else "workload"


def workload_title(workload: str) -> str:
    match = re.match(r"\(([a-zA-Z])\)\s*(.*)", workload)
    if not match:
        return workload
    return f"Workload {match.group(1).upper()}: {match.group(2)}"


def plot_workload(rows: list[dict], workload: str, output_dir: Path) -> None:
    figure, axis = plt.subplots(figsize=(9.5, 5.8))
    minimum = math.inf

    for version, label, color, marker in VERSIONS:
        points = sorted(
            (
                row
                for row in rows
                if row["workload"] == workload and row["version"] == version
            ),
            key=lambda row: row["threads"],
        )
        if not points:
            continue
        minimum = min(minimum, *(point["q25"] for point in points))
        axis.plot(
            [point["threads"] for point in points],
            [point["throughput"] for point in points],
            label=label,
            color=color,
            marker=marker,
            linewidth=2.2,
            markersize=6,
        )
        axis.fill_between(
            [point["threads"] for point in points],
            [point["q25"] for point in points],
            [point["q75"] for point in points],
            color=color,
            alpha=0.14,
        )

    axis.set_title(f"{workload_title(workload)}\n$N = 2^{{26}}$, ranges up to $10^4$")
    axis.set_xlabel("Threads")
    axis.set_ylabel("Throughput, ops/sec, log-based")
    axis.set_yscale("log")
    axis.yaxis.set_major_locator(LogLocator(base=10, subs=(1.0,)))
    axis.yaxis.set_major_formatter(LogFormatterMathtext(base=10, labelOnlyBase=True))
    axis.yaxis.set_minor_locator(LogLocator(base=10, subs=range(2, 10)))
    axis.yaxis.set_minor_formatter(NullFormatter())
    axis.set_ylim(bottom=10 ** math.floor(math.log10(minimum)))
    axis.set_xticks(range(1, 12))
    axis.grid(True, which="both", linestyle="--", alpha=0.35)
    axis.spines[["top", "right"]].set_visible(False)
    axis.legend()
    figure.tight_layout()

    output_dir.mkdir(parents=True, exist_ok=True)
    name = f"throughput_{workload_code(workload)}"
    figure.savefig(output_dir / f"{name}.png", dpi=180, bbox_inches="tight")
    plt.close(figure)


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV
    selected_workload = sys.argv[2].lower() if len(sys.argv) > 2 else None
    if not csv_path.is_file():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 1

    rows = load_rows(csv_path)
    if not rows:
        print(f"No benchmark rows in {csv_path}", file=sys.stderr)
        return 1

    output_dir = csv_path.parent / "plots"
    plotted = 0
    for workload in dict.fromkeys(row["workload"] for row in rows):
        if selected_workload and workload_code(workload) != selected_workload:
            continue
        plot_workload(rows, workload, output_dir)
        plotted += 1
    if plotted == 0:
        print(f"Workload not found: {selected_workload}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
