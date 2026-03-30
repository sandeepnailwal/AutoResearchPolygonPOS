# AutoResearch: Polygon POS Node Optimization

## Project Overview

This project adapts Andrej Karpathy's autoresearch pattern for optimizing a Polygon POS (Bor) node. Instead of iterating on LLM training hyperparameters, the AI agent iterates on node configuration parameters, measuring performance metrics after each experiment.

## How to Use This (for Claude Code)

You are the research agent. Follow the autoresearch loop:

1. Read `program.md` for the full research plan and current phase
2. Read `experiment_log.md` to see what has already been tried
3. Modify `configs/experiment.toml` with your next hypothesis
4. Run `./scripts/run_experiment.sh` (each run takes ~5 minutes)
5. Evaluate with `python3 scripts/evaluate.py --latest`
6. Log results in `experiment_log.md`
7. Repeat

## Project Structure

```
.
├── CLAUDE.md              # This file — agent instructions
├── program.md             # Research plan and optimization targets
├── experiment_log.md      # Running log of all experiments
├── configs/
│   ├── base.toml          # Default Bor config (DO NOT MODIFY)
│   └── experiment.toml    # Current experiment config (MODIFY THIS)
├── scripts/
│   ├── setup_devnet.sh    # One-time setup: build Bor + Heimdall
│   ├── run_experiment.sh  # Run a single experiment (~5 min)
│   ├── evaluate.py        # Analyze experiment results
│   └── generate_load.py   # Generate transaction load for benchmarking
├── results/               # Experiment results (timestamped dirs)
│   └── YYYYMMDD_HHMMSS/
│       ├── config.toml    # Config used for this run
│       ├── metrics.csv    # Time-series CPU/mem/disk metrics
│       ├── node.log       # Full node output
│       └── summary.txt    # Quick summary
├── data/                  # Node data (gitignored)
│   ├── bor/               # Bor chain data
│   └── bor-src/           # Bor source code
└── bin/                   # Compiled binaries (gitignored)
```

## Key Commands

```bash
# First-time setup
./scripts/setup_devnet.sh

# Run an experiment
./scripts/run_experiment.sh

# Evaluate latest results
python3 scripts/evaluate.py --latest

# Compare two experiments
python3 scripts/evaluate.py --compare results/DIR1 results/DIR2

# Generate load during experiment
python3 scripts/generate_load.py --tps 20 --duration 240
```

## Configuration Tuning Priority

Focus experiments on these high-impact parameters (in order):
1. Cache allocation (`[cache]` section)
2. Database compaction (`[leveldb]` section)
3. Transaction pool sizing (`[txpool]` section)
4. Sync mode and GC mode
5. Parallel EVM (`[parallelevm]` section)
6. Network peer limits

## Important Notes

- Always compare against the baseline (Experiment 0 with default config)
- Change one variable (or small related group) per experiment
- If the node crashes, record the crash and revert to last working config
- Save breakthrough configs to `configs/checkpoints/` with descriptive names
- The devnet uses `--dev` mode with 2-second block periods
