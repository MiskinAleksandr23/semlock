Run the complete sweep:

```bash
python3 bench/run_sweep.py
```

Edit `bench/sweep_config.py` to set the partition count, LongAdder stripe
count, array size, maximum query length, requests per worker, and iterations.
To run only selected implementations while keeping the full 1–11 thread
sweep, list them on the command line:

```bash
python3 bench/run_sweep.py no-lock v2-long-adder
```

Every invocation creates a new `benchmark_runs/<timestamp>/` directory with
the effective `config.json`, CSV data, log, Markdown report, and both median
and arithmetic-mean plots. The shaded area is the 25th–75th percentile
interval. The Y axis is logarithmic.
