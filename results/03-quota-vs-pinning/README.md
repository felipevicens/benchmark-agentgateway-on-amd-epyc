# Quota vs. pinning

This experiment reuses two runs already captured under `../02-cpu-quota/`,
since it's the same single-container-vs-mock-server harness, just compared
side by side:

| Configuration | Result folder |
|---|---|
| `--cpus 32` (quota only, unpinned) | [`../02-cpu-quota/cpus-32`](../02-cpu-quota/cpus-32) |
| `--cpuset-cpus 0-15,160-175` (1 cache domain + SMT) | [`../02-cpu-quota/cpuset-1domain-smt`](../02-cpu-quota/cpuset-1domain-smt) |
| `--cpuset-cpus 0-31` (2 cache domains, no SMT) | [`../02-cpu-quota/cpuset-2domains-nosmt`](../02-cpu-quota/cpuset-2domains-nosmt) |

See the main [README](../../README.md) for the resulting numbers and commands.
