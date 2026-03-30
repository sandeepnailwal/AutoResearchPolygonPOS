# AutoResearch: Polygon POS Node Optimization

## Objective

You are an autonomous research agent optimizing a Polygon POS (Bor) node for maximum performance. Your goal is to iteratively modify node configuration, run experiments, measure results, and converge on optimal settings.

## How This Works

1. **Read** this file and `experiment_log.md` to understand what has been tried
2. **Modify** the node configuration in `configs/experiment.toml`
3. **Run** the experiment using `./scripts/run_experiment.sh`
4. **Evaluate** results by running `python3 scripts/evaluate.py`
5. **Log** your findings in `experiment_log.md`
6. **Repeat** — each experiment cycle should take ~5 minutes

## What You Are Optimizing

A Polygon POS node (Bor client, Go-Ethereum fork) running on a local devnet. The key metrics to optimize are:

### Primary Metrics
- **Block processing time** (lower is better) — time to import and execute blocks
- **Sync speed** (higher is better) — blocks synced per second
- **State trie operations/sec** (higher is better)

### Secondary Metrics
- **Memory usage** (lower is better for same throughput)
- **Disk I/O** (lower is better)
- **Peer connectivity** (stable connections)
- **CPU utilization** (efficient usage, not wasteful spinning)

## Configuration Knobs to Experiment With

### Cache & Memory
- `cache` — Total megabytes of memory for internal caching (default: 1024)
- `cache.database` — Percentage of cache for database (default: 50)
- `cache.trie` — Percentage of cache for trie caching (default: 15)
- `cache.gc` — Percentage of cache for GC (default: 25)
- `cache.snapshot` — Percentage of cache for snapshot (default: 10)
- `cache.noprefetch` — Disable heuristic state prefetch (default: false)
- `cache.preimages` — Enable recording of SHA3 preimages (default: false)
- `cache.triesinmemory` — Number of block states kept in memory (default: 128)

### Database
- `leveldb.compaction.table.size` — LevelDB SSTable size in MB
- `leveldb.compaction.table.count` — LevelDB SSTable count
- `leveldb.compaction.total.size` — Total compaction size limit

### Transaction Pool
- `txpool.locals` — Accounts to treat as locals
- `txpool.nolocals` — Disable local transaction handling
- `txpool.journal` — Disk journal path for local transactions
- `txpool.rejournal` — Re-journal interval (default: 1h)
- `txpool.pricelimit` — Minimum gas price (default: 1)
- `txpool.pricebump` — Price bump to replace existing tx (default: 10)
- `txpool.accountslots` — Min guaranteed slots per account (default: 16)
- `txpool.globalslots` — Max executable tx slots (default: 32768)
- `txpool.accountqueue` — Max non-executable slots per account (default: 64)
- `txpool.globalqueue` — Max non-executable slots total (default: 8192)
- `txpool.lifetime` — Max time non-executable tx queued (default: 3h)

### Networking
- `maxpeers` — Max number of peers (default: 50)
- `maxpendpeers` — Max pending peers (default: 50)

### Sync Mode
- `syncmode` — full, snap, or light
- `gcmode` — full or archive

### Bor-Specific
- `bor.logs` — Enable bor log retrieval
- `bor.heimdall` — Heimdall service URL
- `bor.runheimdall` — Run embedded Heimdall
- `bor.devfakeauthor` — Run with fake author for dev

### EVM / Runtime
- `txlookuplimit` — Number of recent blocks for tx index (default: 2350000)
- `gpo.blocks` — Number of blocks for gas price oracle
- `gpo.percentile` — Percentile for gas price suggestion

## Experiment Strategy

### Phase 1: Baseline
Run the node with default configuration and establish baseline metrics.

### Phase 2: Cache Optimization
Experiment with cache allocation ratios. The default 50/15/25/10 split may not be optimal.

### Phase 3: Database Tuning
Adjust LevelDB compaction parameters for better I/O patterns.

### Phase 4: TxPool Optimization
Tune transaction pool settings for throughput.

### Phase 5: Combined Optimization
Combine the best settings from each phase.

## Rules

1. **Change one thing at a time** (or a small related group) so you can attribute improvements
2. **Always log results** before starting the next experiment
3. **If something crashes**, revert to last working config and note what failed
4. **Compare against baseline**, not just the previous experiment
5. **Run each experiment for at least 5 minutes** for stable measurements
6. **Save promising configs** to `configs/checkpoints/` with descriptive names
