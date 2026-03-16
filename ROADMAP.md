# duckflux — Roadmap

Features deliberately out of scope for v0.3. Deferred to future versions based on real-world demand.

---

- **DAG mode** — Explicit step dependencies (`depends: [stepA, stepB]`) instead of linear sequence. Sequence + parallel covers 95% of cases today, but complex graphs with many cross-dependencies become hard to express linearly.

- **Durability / resume** — Workflow survives a runtime crash and resumes from where it stopped. Requires storage and state serialization decisions; this is a runtime feature, not a spec feature.

- **Matrix / fan-out** — Combinatorial execution (e.g., run tests across 3 Node versions x 2 operating systems). Useful for CI, outside the core use case.

- **Secrets management** — Dedicated credential store with rotation and auditing. `env` is sufficient for now; secret store is an infrastructure decision.

- **Workflow versioning** — Run v1 and v2 simultaneously with gradual migration. Relevant when there are multiple executions in production.

- **Caching between runs** — Reuse outputs from idempotent steps across executions. Performance optimization, not functionality.

- **Backpressure / gates** — Gates that reject incomplete work and force re-execution.

- **Persistent mode** — Workflow running as a daemon, reacting to events continuously instead of single execution.

- **Concurrency control** — Limit parallel executions of the same workflow or specific steps.

- **YAML anchors / fragments** — Reuse of configuration blocks within the same file via YAML anchors.
