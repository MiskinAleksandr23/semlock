#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "matplotlib>=3.10,<4",
# ]
# ///

import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import MaxNLocator

from plot_throughput import (
    DEFAULT_CSV_PATH,
    QUERY_SIZES,
    THREAD_COUNTS,
    configure_style,
    load_rows,
    query_power_label,
    save_figure,
    workload_title,
)


QUERY_COLORS = ("#4C78A8", "#F58518", "#54A24B", "#B279A2")
QUERY_MARKERS = ("o", "s", "^", "D")


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV_PATH
    if not csv_path.is_file():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 1

    rows, _ = load_rows(csv_path)
    if not rows:
        print(f"No complete benchmark rows in {csv_path}", file=sys.stderr)
        return 1

    lookup = {
        (row["workload"], row["max_query_len"], row["threads"], row["version"]): row[
            "throughput"
        ]
        for row in rows
    }
    workloads = sorted({row["workload"] for row in rows})

    configure_style()
    figure, axes = plt.subplots(2, 3, figsize=(16, 8.8), sharex=True)
    for axis, workload in zip(axes.flat, workloads):
        has_data = False
        for max_query_len, color, marker in zip(
            QUERY_SIZES, QUERY_COLORS, QUERY_MARKERS
        ):
            points: list[tuple[int, float]] = []
            for threads in THREAD_COUNTS:
                v1 = lookup.get((workload, max_query_len, threads, "v1"))
                v2 = lookup.get((workload, max_query_len, threads, "v2"))
                if v1 is not None and v2 is not None and v1 > 0:
                    points.append((threads, v2 / v1))

            if not points:
                continue

            has_data = True
            axis.plot(
                [point[0] for point in points],
                [point[1] for point in points],
                color=color,
                marker=marker,
                linewidth=2,
                markersize=5,
            )

        axis.axhline(1.0, color="#555555", linestyle="--", linewidth=1.2)
        axis.set_title(workload_title(workload), fontsize=10)
        axis.set_xlim(0.7, 11.3)
        axis.set_xticks(list(THREAD_COUNTS))
        axis.yaxis.set_major_locator(MaxNLocator(nbins=6))
        axis.set_xlabel("Threads")
        axis.set_ylabel("Throughput ratio (V2 / V1)")
        if not has_data:
            axis.text(
                0.5,
                0.5,
                "Waiting for matched V1/V2 data",
                transform=axis.transAxes,
                ha="center",
                va="center",
                color="#777777",
            )

    for axis in axes.flat[len(workloads) :]:
        axis.set_visible(False)

    legend = [
        Line2D(
            [0],
            [0],
            color=color,
            marker=marker,
            linewidth=2,
            label=query_power_label(max_query_len),
        )
        for max_query_len, color, marker in zip(
            QUERY_SIZES, QUERY_COLORS, QUERY_MARKERS
        )
    ]
    figure.suptitle(
        "V2 / V1 Throughput\nArray size: $2^{12}$", fontsize=15, fontweight="bold"
    )
    figure.legend(
        handles=legend,
        title="Queries up to",
        loc="upper center",
        ncol=4,
        bbox_to_anchor=(0.5, 0.92),
    )
    figure.text(
        0.5,
        0.015,
        "Above 1.0 means V2 has higher throughput",
        ha="center",
        color="#666666",
        fontsize=9,
    )
    figure.tight_layout(rect=(0, 0.04, 1, 0.89))

    output_dir = csv_path.parent / "plots"
    save_figure(figure, output_dir / "v2_speedup_overview")
    plt.close(figure)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
