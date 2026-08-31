# Benchmark Results

Each point contains 20 benchmark iterations. The shaded area is the 25th–75th percentile interval.
The center line is the median below and the arithmetic mean in the second section.
The effective configuration is saved in [config.json](config.json).

## Median throughput

### Workload A: 50% point-set, 50% point-get

![Workload A: 50% point-set, 50% point-get, median](median/throughput_a.png)

### Workload B: 50% point-get, 50% sumRange

![Workload B: 50% point-get, 50% sumRange, median](median/throughput_b.png)

### Workload C: 20% of every operation

![Workload C: 20% of every operation, median](median/throughput_c.png)

### Workload D: 40% get/sumRange, 10% set/addRange

![Workload D: 40% get/sumRange, 10% set/addRange, median](median/throughput_d.png)

### Workload E: 40% get/set, 10% sumRange/addRange

![Workload E: 40% get/set, 10% sumRange/addRange, median](median/throughput_e.png)

### Workload F: 90% addRange, 5% setRange/sumRange

![Workload F: 90% addRange, 5% setRange/sumRange, median](median/throughput_f.png)

## Mean throughput

### Workload A: 50% point-set, 50% point-get

![Workload A: 50% point-set, 50% point-get, mean](mean/throughput_a.png)

### Workload B: 50% point-get, 50% sumRange

![Workload B: 50% point-get, 50% sumRange, mean](mean/throughput_b.png)

### Workload C: 20% of every operation

![Workload C: 20% of every operation, mean](mean/throughput_c.png)

### Workload D: 40% get/sumRange, 10% set/addRange

![Workload D: 40% get/sumRange, 10% set/addRange, mean](mean/throughput_d.png)

### Workload E: 40% get/set, 10% sumRange/addRange

![Workload E: 40% get/set, 10% sumRange/addRange, mean](mean/throughput_e.png)

### Workload F: 90% addRange, 5% setRange/sumRange

![Workload F: 90% addRange, 5% setRange/sumRange, mean](mean/throughput_f.png)
