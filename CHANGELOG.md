# Changelog

## v0.3 (Draft)

### Breaking Changes

#### Removed participant types: `agent` and `human`

- The `agent` and `human` participant types have been **removed** from the specification.
- Agent-specific fields (`model`, `tools`) and human-specific fields (`prompt`) are no longer part of the schema.
- **Migration:** Replace `type: agent` and `type: human` with an appropriate remaining type (`exec`, `http`, `mcp`, `workflow`, or `emit`). Agent orchestration and human-in-the-loop patterns should be implemented via runtime-specific extensions or MCP integrations.

#### Variable namespace redesign: `input`/`output` scoping

- **`input.*` and `output` are now participant-scoped.** The variables `input` and `output` within a CEL expression refer to the **current participant's** input and output, not the workflow's.
- **Workflow I/O moved to `workflow.inputs` and `workflow.output`.** All references to workflow-level inputs must use `workflow.inputs.<field>` (previously `input.<field>`). Workflow output is accessed via `workflow.output` (previously `output`).
- **Migration:** Replace all occurrences of `input.<field>` with `workflow.inputs.<field>` in CEL expressions that reference workflow inputs. Replace top-level `output` references in CEL with `workflow.output`.

### New Features

#### Implicit I/O chain (piping)

- The output of each step is **implicitly passed as input** to the next sequential step, forming a chain analogous to Unix pipes.
- The chained value is accessible to the receiving participant via its `input` variable.
- When a participant has both a chained input and an explicit `input` mapping, the runtime **merges** them:
  - Map + map: merged, explicit keys take precedence.
  - String + string: explicit takes precedence.
  - Incompatible types: runtime error.
- **Chain behavior in control flow:**
  - `if/then/else`: output of the last step in the executed branch.
  - `loop`: output of the last step of the last iteration.
  - `parallel`: an **array** of outputs from all branches, in declaration order.

#### Anonymous inline participants

- Inline participants in the `flow` no longer require the `as` field.
- Anonymous participants (without `as`) produce output accessible **only via the implicit I/O chain**. They cannot be referenced by name in CEL expressions.
- Anonymous participants are permitted in all control flow constructs (`if`, `loop`, `parallel`), with the following behavior:
  - In `if` and `loop`: chain operates linearly within each branch/iteration.
  - In `parallel`: output is included positionally in the aggregated output array, but is not individually addressable.

#### Named inline participant uniqueness

- Named inline participants (`as` field) MUST have unique names. The `as` value MUST NOT conflict with any key in the `participants` block or any other inline `as` value.
- Named inline participants remain non-reusable but their results are fully addressable by name.

### Changes

- Minimum valid document simplified: `flow: [{ type: exec, run: "..." }]` is now valid (no `as` required).
- `flow` requirement clarified: the `flow` field is mandatory and MUST be a non-empty array (at least one step).
- Validation rules updated: parser must check inline `as` uniqueness and I/O chain merge compatibility.
- Sub-workflow documentation expanded to include both definition modes: reusable participant (`participants`) and inline step in `flow`.
- `emit` acknowledged mode now explicitly documents timeout handling with `onTimeout` (`fail` or `skip`, default `fail`).
- `workflow.*` namespace expanded: now includes `workflow.inputs` and `workflow.output` in addition to `workflow.id`, `workflow.name`, `workflow.version`.
- Reserved names list unchanged: `workflow`, `execution`, `input`, `output`, `env`, `loop`, `event`.

### Spec Version

- Specification version bumped from `0.2` to `0.3`.

---

## Previous Decisions

Design decisions made during the development of this spec, with rationale:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Expression language | Google CEL | Runtime-agnostic (Go, Rust, JS), sandboxed, type-checked at parse time, familiar syntax. |
| Variable access | Direct by name (`reviewer.output`) | Better DX than `steps.reviewer.output`. Tradeoff: shared namespace with reserved words. `reviewer.output.approved` is more natural and less verbose than `steps.reviewer.output.approved` — enforced at parse time. |
| I/O variable scoping | `input`/`output` = participant, `workflow.inputs`/`workflow.output` = workflow | Participant-scoped `input` is more natural (like function parameters). Workflow I/O is namespaced to avoid collision. |
| Implicit I/O chain | Output of step N chains as input to step N+1 | Unix pipe analogy. Enables anonymous participants and reduces boilerplate for linear flows. |
| Step output on re-execution | Last execution only | Simpler mental model. `reviewer.output` always means "the most recent result". |
| Input/Output default | String | Like stdin/stdout — the universal interface. Schema is opt-in via JSON Schema. |
| Schema format | JSON Schema in YAML | Industry standard, validators available in every language. |
| Error handling levels | Participant (default) + flow (override) | Follows the same precedence pattern as timeout. |
| Workflow output default | Last executed step | Convention over configuration. Explicit mapping available but not required. |
| Inline participants | `as` optional | Named inline participants are addressable by name. Anonymous inline (no `as`) output is only accessible via implicit I/O chain. |
| Loop context rename | `as` field | Allows `attempt.index` instead of `loop.index` for semantic clarity. |
| Events | `emit` + `wait` | Bidirectional: emit publishes, wait subscribes. Events propagate internally too. |
| `participants` block | Optional | Minimal workflows can be fully inline. Block exists for reuse. |
| Triggers | Deferred to runtime | Trigger types and configuration are infrastructure decisions, not spec decisions. |
| Working directory variables | `execution.cwd` + `<step>.cwd` | Observability: base cwd is exposed in execution context, effective cwd per step in step result. Allows expressions to reference the resolved working directory. |
