#!/usr/bin/env python3

import csv
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import sweep_config as config


ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = ROOT / "benchmark_runs"

THREAD_COUNTS = range(1, 12)
VERSIONS = (
    ("v1", ("-Dbench-v2=false",)),
    ("v1-long-adder", ("-Dbench-long-adder=true",)),
    ("v2", ("-Dbench-v2=true",)),
    ("v2-long-adder", ("-Dbench-v2-long-adder=true",)),
    ("no-lock", ("-Dbench-no-lock=true",)),
)
VERSION_BY_NAME = dict(VERSIONS)

CSV_FIELDS = (
    "version",
    "parts_count",
    "stripe_count",
    "array_len",
    "max_query_len",
    "threads",
    "work_count",
    "iterations",
    "items_per_run",
    "workload",
    "total_ns",
    "mean_ns",
    "stddev_ns",
    "min_ns",
    "max_ns",
    "p75_ns",
    "p99_ns",
    "p995_ns",
    "items_per_second",
    "timings_ns",
)


def create_run_dir() -> Path:
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
    name = f"{timestamp}-p{config.PARTS_COUNT}-s{config.STRIPE_COUNT}"
    run_dir = RUNS_DIR / name
    run_dir.mkdir()
    return run_dir


def validate_config(version_names: list[str]) -> str | None:
    numeric_values = {
        "PARTS_COUNT": config.PARTS_COUNT,
        "STRIPE_COUNT": config.STRIPE_COUNT,
        "ARRAY_LEN": config.ARRAY_LEN,
        "MAX_QUERY_LEN": config.MAX_QUERY_LEN,
        "WORK_COUNT": config.WORK_COUNT,
        "ITERATIONS": config.ITERATIONS,
    }
    for name, value in numeric_values.items():
        if not isinstance(value, int) or value <= 0:
            return f"{name} must be a positive integer"
    if config.ARRAY_LEN % config.PARTS_COUNT != 0:
        return "ARRAY_LEN must be divisible by PARTS_COUNT"
    if config.MAX_QUERY_LEN >= config.ARRAY_LEN:
        return "MAX_QUERY_LEN must be smaller than ARRAY_LEN"
    if config.ITERATIONS > 0xFFFF_FFFF:
        return "ITERATIONS must fit in u32"
    if not version_names:
        return "at least one implementation must be selected"
    unknown = [name for name in version_names if name not in VERSION_BY_NAME]
    if unknown:
        return f"unknown implementation: {', '.join(unknown)}"
    if len(set(version_names)) != len(version_names):
        return "implementations must not be repeated"
    return None


def write_run_config(run_dir: Path, version_names: list[str]) -> None:
    effective_config = {
        "parts_count": config.PARTS_COUNT,
        "stripe_count": config.STRIPE_COUNT,
        "array_len": config.ARRAY_LEN,
        "max_query_len": config.MAX_QUERY_LEN,
        "work_count_per_thread": config.WORK_COUNT,
        "iterations": config.ITERATIONS,
        "thread_counts": list(THREAD_COUNTS),
        "versions": version_names,
    }
    (run_dir / "config.json").write_text(
        json.dumps(effective_config, indent=2) + "\n",
        encoding="utf-8",
    )


def workload_title(workload: str) -> tuple[str, str]:
    match = re.match(r"\(([a-zA-Z])\)\s*(.*)", workload)
    if not match:
        return "workload", workload
    return match.group(1).lower(), f"Workload {match.group(1).upper()}: {match.group(2)}"


def write_report(csv_path: Path, report_path: Path) -> None:
    with csv_path.open(newline="", encoding="utf-8") as csv_file:
        workloads = list(
            dict.fromkeys(row["workload"] for row in csv.DictReader(csv_file))
        )

    lines = [
        "# Benchmark Results",
        "",
        f"Each point contains {config.ITERATIONS} benchmark iterations. The shaded area is the "
        "25th–75th percentile interval.",
        "The center line is the median below and the arithmetic mean in the second section.",
        "The effective configuration is saved in [config.json](config.json).",
        "",
        "## Median throughput",
        "",
    ]
    for workload in workloads:
        code, title = workload_title(workload)
        lines.extend(
            (
                f"### {title}",
                "",
                f"![{title}, median](plots/median/throughput_{code}.png)",
                "",
            )
        )

    lines.extend(("## Mean throughput", ""))
    for workload in workloads:
        code, title = workload_title(workload)
        lines.extend(
            (
                f"### {title}",
                "",
                f"![{title}, mean](plots/mean/throughput_{code}.png)",
                "",
            )
        )

    report_path.write_text("\n".join(lines), encoding="utf-8")


def build_reports(csv_path: Path, log_file) -> int:
    plot_script = ROOT / "bench" / "plot_throughput.py"
    for statistic in ("median", "mean"):
        output_dir = csv_path.parent / "plots" / statistic
        command = [
            "uv",
            "run",
            str(plot_script),
            str(csv_path),
            "--statistic",
            statistic,
            "--output-dir",
            str(output_dir),
        ]
        log_file.write(f"$ {' '.join(command)}\n")
        log_file.flush()
        process = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        if process.stdout:
            log_file.write(process.stdout)
        if process.stderr:
            log_file.write(process.stderr)
        log_file.flush()
        if process.returncode != 0:
            return process.returncode

    write_report(csv_path, csv_path.parent / "BENCHMARKS.md")
    return 0


def main() -> int:
    if any(argument in ("-h", "--help") for argument in sys.argv[1:]):
        choices = ", ".join(VERSION_BY_NAME)
        print(f"Usage: {Path(sys.argv[0]).name} [IMPLEMENTATION ...]")
        print(f"Available implementations: {choices}")
        return 0

    version_names = list(sys.argv[1:] or config.DEFAULT_VERSIONS)
    config_error = validate_config(version_names)
    if config_error:
        choices = ", ".join(VERSION_BY_NAME)
        print(f"Configuration error: {config_error}", file=sys.stderr)
        print(f"Available implementations: {choices}", file=sys.stderr)
        return 2
    selected_versions = tuple((name, VERSION_BY_NAME[name]) for name in version_names)

    run_dir = create_run_dir()
    csv_path = run_dir / "sweep.csv"
    log_path = run_dir / "sweep.log"
    write_run_config(run_dir, version_names)
    print(f"Run directory: {run_dir.relative_to(ROOT)}", flush=True)

    total = len(THREAD_COUNTS) * len(selected_versions)
    completed = 0

    with log_path.open("w", encoding="utf-8") as log_file:
        with csv_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
            writer.writeheader()
            csv_file.flush()

            for threads in THREAD_COUNTS:
                for version, version_args in selected_versions:
                    completed += 1
                    label = f"[{completed}/{total}] {version}, threads={threads}"
                    print(label, flush=True)

                    command = [
                        "zig",
                        "build",
                        "bench",
                        "--summary",
                        "none",
                        *version_args,
                        f"-Dbench-threads={threads}",
                        f"-Dbench-parts-count={config.PARTS_COUNT}",
                        f"-Dbench-stripe-count={config.STRIPE_COUNT}",
                        f"-Dbench-array-len={config.ARRAY_LEN}",
                        f"-Dbench-max-query-len={config.MAX_QUERY_LEN}",
                        f"-Dbench-work-count={config.WORK_COUNT}",
                        f"-Dbench-iterations={config.ITERATIONS}",
                        "-Dbench-json=true",
                    ]
                    log_file.write(f"{label}\n$ {' '.join(command)}\n")
                    log_file.flush()

                    process = subprocess.run(
                        command, cwd=ROOT, text=True, capture_output=True
                    )
                    if process.stderr:
                        log_file.write(process.stderr)
                    if process.returncode != 0:
                        log_file.write(process.stdout)
                        log_file.flush()
                        print(f"Benchmark failed; see {log_path}", file=sys.stderr)
                        return process.returncode

                    try:
                        results = json.loads(process.stdout)
                    except json.JSONDecodeError:
                        log_file.write(process.stdout)
                        log_file.flush()
                        print(f"Invalid JSON; see {log_path}", file=sys.stderr)
                        return 1

                    for result in results:
                        statistics = result["timing_statistics"]
                        percentiles = statistics["percentiles"]
                        writer.writerow(
                            {
                                "version": version,
                                "parts_count": config.PARTS_COUNT,
                                "stripe_count": config.STRIPE_COUNT,
                                "array_len": config.ARRAY_LEN,
                                "max_query_len": config.MAX_QUERY_LEN,
                                "threads": threads,
                                "work_count": config.WORK_COUNT,
                                "iterations": config.ITERATIONS,
                                "items_per_run": threads * config.WORK_COUNT,
                                "workload": result["name"],
                                "total_ns": statistics["total"],
                                "mean_ns": statistics["mean"],
                                "stddev_ns": statistics["stddev"],
                                "min_ns": statistics["min"],
                                "max_ns": statistics["max"],
                                "p75_ns": percentiles["p75"],
                                "p99_ns": percentiles["p99"],
                                "p995_ns": percentiles["p995"],
                                "items_per_second": result["throughput"][
                                    "items_per_second"
                                ],
                                "timings_ns": json.dumps(
                                    result["timings"], separators=(",", ":")
                                ),
                            }
                        )

                    csv_file.flush()
                    log_file.flush()

        report_status = build_reports(csv_path, log_file)
        if report_status != 0:
            print(f"Plotting failed; see {log_path}", file=sys.stderr)
            return report_status

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
