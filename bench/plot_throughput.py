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
from matplotlib.lines import Line2D
from matplotlib.ticker import MaxNLocator


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV_PATH = ROOT / "bench" / "results" / "sweep.csv"
QUERY_SIZES = (1 << 9, 1 << 10, 1 << 11, 1 << 12)
THREAD_COUNTS = range(1, 12)
VERSIONS = ("v1", "v2")
COLORS = {"v1": "#4C78A8", "v2": "#F58518"}
MARKERS = {"v1": "o", "v2": "s"}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def load_rows(csv_path: Path) -> tuple[list[dict], int]:
    rows: list[dict] = []
    skipped = 0

    with csv_path.open(newline="", encoding="utf-8") as csv_file:
        for raw in csv.DictReader(csv_file):
            try:
                version = raw["version"].strip().lower()
                timings = [int(value) for value in json.loads(raw["timings_ns"])]
                items_per_run = int(raw["items_per_run"])
                if version not in VERSIONS or not timings or any(value <= 0 for value in timings):
                    raise ValueError

                sample_throughput = [
                    items_per_run * 1_000_000_000.0 / timing for timing in timings
                ]
                rows.append(
                    {
                        "version": version,
                        "max_query_len": int(raw["max_query_len"]),
                        "threads": int(raw["threads"]),
                        "workload": raw["workload"],
                        "throughput": float(raw["items_per_second"]),
                        "q25": percentile(sample_throughput, 0.25),
                        "q75": percentile(sample_throughput, 0.75),
                    }
                )
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                skipped += 1

    return rows, skipped


def configure_style() -> None:
    plt.rcParams.update(
        {
            "font.size": 10,
            "axes.titleweight": "bold",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "grid.alpha": 0.35,
            "grid.linestyle": "--",
            "figure.facecolor": "#FAFAFA",
            "axes.facecolor": "#FFFFFF",
            "savefig.facecolor": "#FAFAFA",
        }
    )


def query_label(max_query_len: int) -> str:
    power = int(math.log2(max_query_len))
    return f"Queries up to $2^{{{power}}}$"


def query_power_label(max_query_len: int) -> str:
    power = int(math.log2(max_query_len))
    return f"$2^{{{power}}}$"


def workload_code(workload: str) -> str:
    match = re.match(r"\(([a-zA-Z0-9]+)\)", workload)
    return match.group(1).lower() if match else "workload"


def workload_title(workload: str) -> str:
    match = re.match(r"\(([a-zA-Z0-9]+)\)\s*(.*)", workload)
    if not match:
        return workload
    return f"Workload {match.group(1).upper()}: {match.group(2)}"


def save_figure(figure: plt.Figure, output_base: Path) -> None:
    output_base.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_base.with_suffix(".png"), dpi=180, bbox_inches="tight")
    figure.savefig(output_base.with_suffix(".svg"), bbox_inches="tight")


def plot_workload(rows: list[dict], workload: str, output_dir: Path) -> None:
    figure, axes = plt.subplots(2, 2, figsize=(13.5, 8.5), sharex=True)

    for axis, max_query_len in zip(axes.flat, QUERY_SIZES):
        has_data = False
        for version in VERSIONS:
            points = sorted(
                (
                    row
                    for row in rows
                    if row["workload"] == workload
                    and row["max_query_len"] == max_query_len
                    and row["version"] == version
                ),
                key=lambda row: row["threads"],
            )
            if not points:
                continue

            has_data = True
            threads = [row["threads"] for row in points]
            throughput = [row["throughput"] / 1_000_000.0 for row in points]
            q25 = [row["q25"] / 1_000_000.0 for row in points]
            q75 = [row["q75"] / 1_000_000.0 for row in points]

            axis.plot(
                threads,
                throughput,
                color=COLORS[version],
                marker=MARKERS[version],
                linewidth=2.2,
                markersize=5.5,
                label=version.upper(),
            )
            axis.fill_between(threads, q25, q75, color=COLORS[version], alpha=0.14)

        axis.set_title(query_label(max_query_len))
        axis.set_xlim(0.7, 11.3)
        axis.set_xticks(list(THREAD_COUNTS))
        axis.yaxis.set_major_locator(MaxNLocator(nbins=6))
        axis.set_xlabel("Threads")
        axis.set_ylabel(r"Throughput ($\times 10^6$ requests/s)")
        if not has_data:
            axis.text(
                0.5,
                0.5,
                "Waiting for data",
                transform=axis.transAxes,
                ha="center",
                va="center",
                color="#777777",
            )

    legend = [
        Line2D(
            [0],
            [0],
            color=COLORS[version],
            marker=MARKERS[version],
            linewidth=2.2,
            label=version.upper(),
        )
        for version in VERSIONS
    ]
    figure.suptitle(
        f"{workload_title(workload)}\nArray size: $2^{{12}}$",
        fontsize=14,
        fontweight="bold",
        y=0.995,
    )
    figure.legend(handles=legend, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 0.925))
    figure.text(
        0.5,
        0.01,
        "Shaded area: 25th–75th percentile across benchmark runs",
        ha="center",
        color="#666666",
        fontsize=9,
    )
    figure.tight_layout(rect=(0, 0.035, 1, 0.89))

    save_figure(figure, output_dir / f"throughput_{workload_code(workload)}")
    plt.close(figure)


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV_PATH
    if not csv_path.is_file():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 1

    rows, _ = load_rows(csv_path)
    if not rows:
        print(f"No complete benchmark rows in {csv_path}", file=sys.stderr)
        return 1

    configure_style()
    output_dir = csv_path.parent / "plots"
    workloads = sorted({row["workload"] for row in rows})
    for workload in workloads:
        plot_workload(rows, workload, output_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
