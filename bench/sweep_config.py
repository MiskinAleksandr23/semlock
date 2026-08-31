# Parameters shared by every implementation selected for one sweep.
# ARRAY_LEN must be divisible by PARTS_COUNT.
PARTS_COUNT = 64  # Used by V2 and V2 + LongAdder.
STRIPE_COUNT = 4  # Used by both LongAdder variants.
ARRAY_LEN = 1 << 26
MAX_QUERY_LEN = 10_000  # Must be smaller than ARRAY_LEN.
WORK_COUNT = 1 << 17  # Requests per worker in one benchmark iteration.
ITERATIONS = 20

# Used when run_sweep.py is invoked without algorithm names.
DEFAULT_VERSIONS = (
    "v1",
    "v1-long-adder",
    "v2",
    "v2-long-adder",
    "no-lock",
)
