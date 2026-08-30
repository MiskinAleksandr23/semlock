Run the complete sweep and then build the figures:

```bash
python3 bench/run_sweep.py
uv run bench/plot_throughput.py
```

The line is the median throughput across 10 runs; the shaded area is the
25th–75th percentile interval. The Y axis is logarithmic.
