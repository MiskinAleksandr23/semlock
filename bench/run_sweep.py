#!/usr/bin/env python3

import csv
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "bench" / "results"
CSV_PATH = RESULTS_DIR / "sweep.csv"
LOG_PATH = RESULTS_DIR / "sweep.log"

ARRAY_LEN = 1 << 26
MAX_QUERY_LEN = 10_000
WORK_COUNT = 1 << 18
ITERATIONS = 20
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


def main() -> int:
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] not in VERSION_BY_NAME):
        choices = ", ".join(VERSION_BY_NAME)
        print(f"Usage: {Path(sys.argv[0]).name} [{choices}]", file=sys.stderr)
        return 2

    selected_version = sys.argv[1] if len(sys.argv) == 2 else None
    selected_versions = (
        ((selected_version, VERSION_BY_NAME[selected_version]),)
        if selected_version
        else VERSIONS
    )

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    preserved_rows = []
    if selected_version and CSV_PATH.is_file():
        with CSV_PATH.open(newline="", encoding="utf-8") as existing_file:
            for row in csv.DictReader(existing_file):
                if row.get("version") == selected_version:
                    continue
                row["work_count"] = str(WORK_COUNT)
                row["items_per_run"] = str(int(row["threads"]) * WORK_COUNT)
                preserved_rows.append(row)

    total = len(THREAD_COUNTS) * len(selected_versions)
    completed = 0

    log_mode = "a" if selected_version else "w"
    with CSV_PATH.open("w", newline="", encoding="utf-8") as csv_file, LOG_PATH.open(
        log_mode, encoding="utf-8"
    ) as log_file:
        writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(preserved_rows)
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
                    "-Dbench-json=true",
                ]
                log_file.write(f"{label}\n$ {' '.join(command)}\n")
                log_file.flush()

                process = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
                if process.stderr:
                    log_file.write(process.stderr)
                if process.returncode != 0:
                    log_file.write(process.stdout)
                    log_file.flush()
                    print(f"Benchmark failed; see {LOG_PATH}", file=sys.stderr)
                    return process.returncode

                try:
                    results = json.loads(process.stdout)
                except json.JSONDecodeError:
                    log_file.write(process.stdout)
                    log_file.flush()
                    print(f"Invalid JSON; see {LOG_PATH}", file=sys.stderr)
                    return 1

                for result in results:
                    statistics = result["timing_statistics"]
                    percentiles = statistics["percentiles"]
                    writer.writerow(
                        {
                            "version": version,
                            "array_len": ARRAY_LEN,
                            "max_query_len": MAX_QUERY_LEN,
                            "threads": threads,
                            "work_count": WORK_COUNT,
                            "iterations": ITERATIONS,
                            "items_per_run": threads * WORK_COUNT,
                            "workload": result["name"],
                            "total_ns": statistics["total"],
                            "mean_ns": statistics["mean"],
                            "stddev_ns": statistics["stddev"],
                            "min_ns": statistics["min"],
                            "max_ns": statistics["max"],
                            "p75_ns": percentiles["p75"],
                            "p99_ns": percentiles["p99"],
                            "p995_ns": percentiles["p995"],
                            "items_per_second": result["throughput"]["items_per_second"],
                            "timings_ns": json.dumps(result["timings"], separators=(",", ":")),
                        }
                    )

                csv_file.flush()
                log_file.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
