# duckflux — Declarative Workflow DSL

A minimal, deterministic, runtime-agnostic DSL for orchestrating workflows through declarative YAML specs.

---

## 1. Background

### 1.1 The Problem

Workflow orchestration tooling has evolved in many directions — CI/CD pipelines, data engineering DAGs, durable execution frameworks, visual automation builders — but none of them solve a fundamental need: a simple, declarative spec that a developer can write in minutes, read in seconds, and run anywhere.

The existing landscape falls short in different ways:

| Tool | Original purpose | Where it fails |
|------|-----------------|----------------|
| Argo Workflows | CI/CD on Kubernetes | Extreme complexity. YAML that reads like an algorithm. Turing-complete DSL disguised as config. |
| Tekton | Cloud-native CI/CD | Same complexity problem as Argo, with additional CRD overhead. |
| GitHub Actions | CI/CD for GitHub | Vendor lock-in. No real conditional loops — workarounds require unrolling or recursive reusable workflows. |
| Temporal / Inngest | Durable workflows | Code-first (Go, TypeScript, Python SDKs). The code IS the spec — no declarative layer. |
| Airflow / Prefect | Data pipelines | Python-first. DAGs are acyclic by definition — conditional loops are architecturally impossible without recursive sub-DAG hacks. |
| n8n / Make | Visual automation | Visual-first, JSON-heavy specs. Loop constructs require JavaScript function nodes and circular connections. Specs are unreadable as text. |
| Lobster | Shell automation | Intentionally minimal. Linear pipelines with approval gates, but no loops, no parallelism, no conditionals. |
| Ralph Orchestrator | Agent loop framework | Event-driven with implicit flow. The execution order emerges from event routing — determinism is partial, not guaranteed. |

### 1.2 The Gap

```
What developers want:     Write a flow in 5 minutes, run it anywhere.
What tools offer:          200-line YAML or a language-specific SDK.
```

No existing tool solves: **simple declarative spec + runtime-agnostic execution + first-class control flow (loops, conditionals, parallelism)**.

### 1.3 Design Exploration

Three approaches were evaluated before arriving at the current design:

**Approach 1: Extend an existing format (Argo).** Argo's YAML is expressive but its power came from incremental feature additions over 6+ years, resulting in a DSL that is effectively Turing-complete. A conditional loop in Argo requires template recursion, manual iteration counters, and string-interpolated type casting — 13+ lines for what should be 6.

**Approach 2: Mermaid as executable spec.** Mermaid sequence diagrams already have `loop`, `par`, and `alt` constructs. The DX for reading and writing is excellent, and diagrams render natively in GitHub, Notion, and VS Code. However, extending Mermaid for real workflow concerns (retry policies, timeouts, error handling, typed variables) requires hacks — `Note` blocks for config, `$var` for expressions — and creates a custom parser that is as proprietary as a new YAML format, just disguised as something familiar.

**Approach 3: Minimal custom YAML (chosen).** A new format, intentionally constrained, inspired by Mermaid's visual clarity but with the extensibility and tooling ecosystem of YAML. The tradeoff: a new DSL to learn, but one designed to be readable in 5 seconds and writable in 5 minutes.

---

## 2. Design Principles

1. **Readable in 5 seconds** — Any developer understands the flow by glancing at the spec. No indirection, no template references, no implicit ordering.

2. **Minimal by default** — Features are only added when absolutely necessary. The DSL resists complexity. If something can be solved with an existing primitive, a new one is not introduced.

3. **Convention over configuration** — Sensible defaults everywhere. Explicit override when needed. A workflow with zero configuration still works.

4. **Steps are steps** — Scripts, HTTP calls, human approvals, sub-workflows — all are treated as participants with the same interface: input in, output out.

5. **String by default** — Every participant receives and returns strings unless a schema is explicitly defined. Like stdin/stdout — the universal interface. This allows any content type: plain text, JSON, XML, binary.

6. **Runtime-agnostic** — The DSL defines WHAT happens and in WHAT ORDER. The runtime decides HOW. The spec does not assume a specific execution environment, programming language, or infrastructure.

7. **Deterministic flow** — The execution order is explicit and predictable. The flow is what is written — no implicit routing, no emergent ordering from events.

8. **Reuse proven standards** — The DSL does not reinvent what already works. Expressions use Google CEL (battle-tested in Kubernetes, Firebase, and Envoy). Schemas use JSON Schema (the industry standard for data validation). YAML is the format (universal in DevOps and infrastructure). When a well-adopted standard exists for a problem, use it — don't build a proprietary alternative.

---

## 3. Schema Overview

A duckflux workflow is a YAML file with the following top-level structure:

```yaml
flow:
  - type: exec
    run: echo "Hello, duckflux!"
```

The simplest workflow requires only a `flow` with at least one step. Participants can be declared inline (as shown above — named or anonymous) or in a separate `participants` block for reuse.

### 3.1 Top-level Fields

| Field | Required | Description |
|-------|----------|-------------|
| `version` | no | Version of the workflow definition format. Default: `0.3`. Used for compatibility checks by the runtime. |
| `id` | no | Unique identifier for the workflow |
| `name` | no | Human-readable workflow name |
| `version` | no | Version identifier for the workflow definition |
| `defaults` | no | Global defaults (timeout, cwd, etc.) applied to all participants |
| `inputs` | no | Input parameters the workflow accepts from its caller |
| `participants` | no | Named steps that can be referenced in the flow |
| `flow` | yes | The execution sequence — the core of the workflow |
| `output` | no | Explicit output mapping. If omitted, output is the last executed step's output |

---

## 4. Participants

Participants are the building blocks of a workflow. Each participant has a `type` that determines its behavior, and a set of configuration fields that vary by type.

Participants can be defined in three ways:

### 4.1 In the `participants` Block (Reusable)

```yaml
participants:
  tests:
    type: exec
    run: npm test

  notify:
    type: http
    url: https://hooks.slack.com/services/...
    method: POST

flow:
  - tests
  - notify
```

### 4.2 Named Inline in the Flow

```yaml
flow:
  - as: build
    type: exec
    run: npm run build
    timeout: 5m

  - as: test
    type: exec
    run: npm test

  - as: notify
    type: http
    url: https://hooks.slack.com/done
    method: POST
```

Named inline participants use the `as` field to name the step. This name is used to reference outputs (`build.output`, `test.status`, etc.). Named inline participants cannot be reused — use the `participants` block for reusable steps. The `as` value must be unique across all participant names (both reusable and inline).

### 4.3 Anonymous Inline in the Flow

```yaml
flow:
  - type: exec
    run: echo "setup complete"

  - as: deploy
    type: exec
    run: ./deploy.sh
```

Anonymous inline participants omit the `as` field. Their output is accessible only via the implicit I/O chain (see [I/O Chain](#107-implicit-io-chain)) — they cannot be referenced by name in CEL expressions. This is useful for fire-and-forget steps or steps whose output is only consumed by the immediately following step.

### 4.4 Participant Types

| Type | Description |
|------|-------------|
| `exec` | Terminal command execution. Useful for tests, linting, builds, deploys, and any shell operation. |
| `http` | HTTP request. Useful for API integration, webhooks, and external service calls. |
| `mcp` | Request to another MCP server. Useful for delegating tasks across different MCPs or organizations. |
| `workflow` | Reference to another workflow file. Enables composition and reuse. See [Sub-workflows](#8-sub-workflows-composition). |
| `emit` | Emits an event to the event hub. See [Events](#9-events). |

### 4.5 Common Participant Fields

These fields are available on all participant types:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | — | Required. The participant type. |
| `as` | string | — | Display name. Optional for inline participants. If omitted, the participant is anonymous. |
| `timeout` | duration | from `defaults` | Maximum execution time before the step is treated as a failure. |
| `onError` | string | `fail` | Error handling strategy. See [Error Handling](#6-error-handling). |
| `retry` | object | — | Retry configuration. Only applies when `onError: retry`. |
| `input` | string or map | — | Input mapping from workflow data to this participant. |
| `output` | map | — | Output schema definition (JSON Schema, opt-in). |

### 4.6 Type-specific Fields

#### `exec`

| Field | Type | Description |
|-------|------|-------------|
| `run` | string | Shell command to execute. |
| `cwd` | string | Working directory. Supports CEL expressions. |

#### `http`

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | Target URL. Supports CEL expressions. |
| `method` | string | HTTP method: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. |
| `headers` | map | HTTP headers. Values support CEL expressions. |
| `body` | string or map | Request body. Supports CEL expressions. |

#### `workflow`

| Field | Type | Description |
|-------|------|-------------|
| `path` | string | Path to the sub-workflow YAML file. |

#### `emit`

| Field | Type | Description |
|-------|------|-------------|
| `event` | string | Event name to emit. |
| `payload` | string or map | Event payload. CEL expression or map of CEL expressions. |
| `ack` | boolean | If `true`, wait for delivery acknowledgment. Default: `false`. |

### 4.7 Reserved Names

Participant names share the same namespace as runtime variables. The following names are reserved and cannot be used as participant names:

`workflow`, `execution`, `input`, `output`, `env`, `loop`, `event`

The parser must reject workflows that use reserved names as participant identifiers.

---

## 5. Flow Syntax

The `flow` key defines the execution sequence. It is an ordered list of steps, where each step can be:

- A participant reference (string)
- An inline participant definition (object with `as` + `type`)
- A control flow construct (`loop`, `parallel`, `if`, `wait`)
- A participant reference with overrides (object with participant name as key)

### 5.1 Sequential Execution

Steps execute top-to-bottom, one at a time:

```yaml
flow:
  - stepA
  - stepB
  - stepC
```

Or with inline participants:

```yaml
flow:
  - as: stepA
    type: exec
    run: echo "A"

  - as: stepB
    type: exec
    run: echo "B"
```

### 5.2 Conditional Loop

Repeats a set of steps until a CEL condition becomes true, or a maximum iteration count is reached.

```yaml
flow:
  - loop:
      until: reviewer.output.approved == true
      max: 5
      steps:
        - coder
        - reviewer
```

Both `until` and `max` are optional, but at least one must be present. If only `max` is set, the loop runs exactly N times. If only `until` is set, the loop runs indefinitely until the condition is met (use with caution).

Within the loop, all step outputs are overwritten on each iteration — they always reflect the most recent execution.

#### Loop with `as` (Renamed Context)

The loop context variables (`loop.index`, `loop.iteration`, etc.) can be renamed using `as`:

```yaml
flow:
  - loop:
      as: attempt
      max: 3
      steps:
        - coder
        - reviewer:
            when: attempt.index > 0
```

With `as: attempt`, access `attempt.index`, `attempt.iteration`, `attempt.first`, `attempt.last` instead of `loop.*`.

### 5.3 Fixed Loop

Runs a set of steps a fixed number of times, with no exit condition:

```yaml
flow:
  - loop:
      max: 3
      steps:
        - stepA
```

### 5.4 Parallel Execution

Runs multiple steps concurrently. The flow continues only after all parallel steps complete:

```yaml
flow:
  - parallel:
      - stepA
      - stepB
      - stepC
```

Parallel steps can include inline participants:

```yaml
flow:
  - parallel:
      - as: lint
        type: exec
        run: npm run lint

      - as: test
        type: exec
        run: npm test

      - as: typecheck
        type: exec
        run: npm run typecheck
```

### 5.5 Conditional Branching

Evaluates a CEL expression and routes to different branches:

```yaml
flow:
  - stepA
  - if:
      condition: stepA.output.score > 7
      then:
        - stepB
        - stepC
      else:
        - stepD
```

The `else` branch is optional. If omitted and the condition is false, execution continues to the next step after the `if` block.

### 5.6 Guard Condition (`when`)

Any step in the flow can have a `when` guard — a CEL precondition that determines whether the step executes. If the condition evaluates to false, the step is marked as `skipped` and execution continues.

```yaml
flow:
  - coder
  - reviewer
  - deploy:
      when: reviewer.output.approved == true
  - notify:
      when: reviewer.output.approved == false
```

#### `when` vs `if`

`when` is a filter on a single step. `if` creates branches with multiple steps.

Use `when` for simple guards on individual steps:

```yaml
- deploy:
    when: reviewer.output.approved == true
```

Use `if/then/else` when the branch involves multiple steps:

```yaml
- if:
    condition: reviewer.output.approved == true
    then:
      - deploy
      - notifySuccess
    else:
      - rollback
      - notifyFailure
```

### 5.7 Wait

Pauses execution until a condition is met. Three modes are available, detected by the fields present.

#### Wait for Event

```yaml
flow:
  - submitForApproval
  - wait:
      event: "approval.received"
      match: event.requestId == submitForApproval.output.id
      timeout: 24h
      onTimeout: fail
  - deploy
```

The `event` variable in the `match` expression contains the received event payload.

#### Wait for Time (Sleep)

```yaml
flow:
  - prepare
  - wait:
      timeout: 30m
  - execute
```

When only `timeout` is present with no condition, the step acts as a sleep.

#### Wait for Condition (Polling)

```yaml
flow:
  - triggerBuild
  - wait:
      until: buildApi.output.status == "ready"
      poll: 10s
      timeout: 1h
      onTimeout: skip
  - deploy
```

The `until` condition is re-evaluated at the specified `poll` interval.

#### Wait for Specific Time

```yaml
flow:
  - wait:
      until: now >= timestamp("2024-04-01T09:00:00Z")
      poll: 1m
      timeout: 48h
```

### 5.8 Flow-level Overrides

When referencing a participant in the flow, any participant field can be overridden for that specific execution:

```yaml
flow:
  - coder:
      timeout: 30m
      onError: skip
  - reviewer
```

In this example, `coder` uses a 30-minute timeout and `skip` on error for this specific invocation, regardless of what is defined in the participant block. Flow-level overrides always take precedence.

---

## 6. Error Handling

Error handling is configurable at two levels: on the **participant** (default behavior) and in the **flow** (per-invocation override). The flow always takes precedence.

### 6.1 `onError` Values

| Value | Behavior |
|-------|----------|
| `fail` | Stops the workflow immediately. This is the global default. |
| `skip` | Marks the step as `skipped` and continues the flow. |
| `retry` | Re-executes the step according to the `retry` configuration. |
| `<participant>` | Redirects execution to another participant as a fallback. |

### 6.2 Participant-level (Default)

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    onError: retry
    retry:
      max: 3
      backoff: 2s

  reviewer:
    type: exec
    run: ./review.sh
    onError: fail
```

### 6.3 Flow-level (Override)

```yaml
flow:
  - coder:
      onError: skip
  - reviewer
```

Here, `coder` uses `skip` instead of the `retry` defined in the participant block.

### 6.4 Redirect to Another Participant

The `onError` field accepts the name of another participant, enabling fallback chains:

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    onError: fixer

  fixer:
    type: exec
    run: ./fix.sh

  deploy:
    type: exec
    run: ./deploy.sh
    onError: notify

  notify:
    type: http
    url: https://hooks.slack.com/...
    method: POST
```

When `coder` fails, `fixer` takes over. When `deploy` fails, `notify` is called. The participant referenced in `onError` must exist in the participants list.

### 6.5 Retry Configuration

```yaml
retry:
  max: 3           # maximum attempts (required when onError: retry)
  backoff: 2s      # interval between attempts (default: 0s)
  factor: 2        # backoff multiplier (default: 1, no escalation)
```

With `backoff: 2s` and `factor: 2`, the intervals would be: 2s, 4s, 8s.

---

## 7. Timeout and Working Directory

### 7.1 Timeout

Timeout prevents steps from blocking the workflow indefinitely. It is configurable at three levels with clear precedence.

#### Global Default

```yaml
defaults:
  timeout: 5m
```

Applies to all steps that do not define their own timeout.

#### Participant-level

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    timeout: 15m

  deploy:
    type: exec
    run: ./deploy.sh
    timeout: 2m
```

#### Flow-level Override

```yaml
flow:
  - coder:
      timeout: 30m
  - reviewer
```

#### Precedence

```
flow > participant > defaults > runtime default (no timeout)
```

When a step exceeds its timeout, it is treated as a failure and follows the configured `onError` strategy.

### 7.2 Working Directory (`cwd`)

The `cwd` field sets the working directory for `exec` participants. It supports CEL expressions.

#### Global Default

```yaml
defaults:
  cwd: ./packages/core
```

#### Participant-level

```yaml
participants:
  build:
    type: exec
    run: npm run build
    cwd: ./packages/core
```

#### Flow-level (Inline)

```yaml
flow:
  - as: build
    type: exec
    run: npm run build
    cwd: workflow.inputs.packagePath
```

#### Precedence

```
participant.cwd > defaults.cwd > CLI --cwd > process cwd
```

---

## 8. Sub-workflows (Composition)

Workflows can reference other `.yaml` files as steps, enabling composition and reuse. This prevents large workflows from becoming unmanageable single files.

### 8.1 As a Participant

```yaml
participants:
  reviewCycle:
    type: workflow
    path: ./review-loop.yaml
    input:
      repo: workflow.inputs.repoUrl
      branch: workflow.inputs.branch

flow:
  - coder
  - reviewCycle
  - deploy
```

The sub-workflow receives mapped `input` and its `output` is accessible as `reviewCycle.output.*`.

### 8.2 Inline in the Flow

```yaml
flow:
  - coder
  - as: reviewCycle
    type: workflow
    path: ./review-loop.yaml
    input:
      repo: workflow.inputs.repoUrl
  - deploy
```

### 8.3 Behavior

- Sub-workflows have their own `execution.context` (isolated from the parent).
- `onError` and `timeout` from the parent participant apply to the sub-workflow as a whole.
- The `output` defined in the sub-workflow is mapped as `<step>.output` in the parent workflow.
- Sub-workflows can be nested (workflow calls workflow calls workflow).
- Sub-workflow paths are resolved relative to the parent workflow's directory.

---

## 9. Events

duckflux supports event-driven communication through `emit` (publishing) and `wait` (subscribing).

### 9.1 Emitting Events

The `emit` participant type publishes an event to the event hub:

```yaml
participants:
  notifyProgress:
    type: emit
    event: "task.progress"
    payload:
      taskId: workflow.inputs.taskId
      status: coder.output.status
      timestamp: execution.startedAt
```

Or inline:

```yaml
flow:
  - as: notifyComplete
    type: emit
    event: "task.completed"
    payload: reviewer.output
```

#### Fire-and-Forget vs Acknowledgment

By default, `emit` is fire-and-forget — it dispatches the event and continues immediately:

```yaml
- as: notify
  type: emit
  event: "build.started"
  payload: build.output
```

With `ack: true`, the step blocks until the event hub confirms delivery:

```yaml
- as: notifyCritical
  type: emit
  event: "deploy.started"
  payload: deploy.output
  ack: true
  timeout: 10s
  onTimeout: skip
```

#### Payload Format

The `payload` can be a single CEL expression (outputs a string/value):

```yaml
payload: coder.output
```

Or a structured object with CEL expressions as values:

```yaml
payload:
  taskId: workflow.inputs.taskId
  status: coder.output.status
  timestamp: execution.startedAt
```

### 9.2 Waiting for Events

The `wait` flow construct can pause execution until an event is received:

```yaml
flow:
  - submitRequest
  - wait:
      event: "approval.response"
      match: event.requestId == submitRequest.output.id
      timeout: 24h
      onTimeout: fail
  - processApproval
```

The `event` variable in the `match` expression contains the received event payload.

### 9.3 Internal Event Propagation

Events emitted via `emit` are also published internally within the workflow. This means a `wait` step can react to events emitted by earlier steps in the same workflow:

```yaml
flow:
  - parallel:
      - as: worker1
        type: exec
        run: ./process-batch.sh 1
      
      - as: worker2
        type: exec
        run: ./process-batch.sh 2

      - as: monitor
        type: workflow
        path: ./monitor.yaml

  - as: notifyAll
    type: emit
    event: "processing.complete"
    payload:
      results: [worker1.output, worker2.output]
```

The monitor sub-workflow could contain:

```yaml
flow:
  - wait:
      event: "processing.complete"
      timeout: 1h
  - as: report
    type: http
    url: https://api.example.com/report
    method: POST
    body: event
```

---

## 10. Inputs and Outputs

### 10.1 Core Principle: String by Default

Every participant, by default, receives and returns **string**. No schema required. Input is a string, output is a string — like stdin/stdout. This allows any content type: plain text, JSON, XML, binary, or anything else.

Schema is **opt-in**. When defined, it uses JSON Schema (written in YAML) for validation and documentation.

### 10.2 Variable Scoping: Workflow vs Participant

The variables `input` and `output` are **participant-scoped** — within any CEL expression evaluated in the context of a participant, they refer to **that participant's own** input and output:

- `input` — The resolved input data received by the current participant (read-only).
- `output` — The output produced by the current participant (write-only, set by the runtime after execution).

Workflow-level I/O is accessed via:

- `workflow.inputs.*` — The workflow's input parameters, as defined in the `inputs` field.
- `workflow.output` — The workflow's output, as defined in the `output` field.

This separation allows participants to access their own arguments naturally (like function parameters) while still being able to reference the workflow's global inputs when needed.

### 10.3 Workflow Inputs

Workflow inputs are defined in the top-level `inputs` field and accessed in CEL as `workflow.inputs.<field>`.

Without schema (everything is a string):

```yaml
inputs:
  repoUrl:
  branch:
```

With schema (JSON Schema in YAML, validated by the runtime):

```yaml
inputs:
  repoUrl:
    type: string
    format: uri
    required: true
    description: "Repository URL"
  branch:
    type: string
    default: "main"
  maxRetries:
    type: integer
    minimum: 1
    maximum: 10
    default: 3
  tags:
    type: array
    items:
      type: string
  verbose:
    type: boolean
    default: false
```

The `required: true` shortcut inside each field is syntactic sugar — the parser normalizes it to canonical JSON Schema format (`required: [...]` at the parent object level) at validation time.

If `type` is not specified, the field is treated as `string`.

### 10.4 Participant Explicit Input Mapping

Each participant can explicitly map data from the workflow context to its inputs via CEL expressions. Without schema, it is direct string passthrough:

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    input: workflow.inputs.taskDescription
```

With structured mapping:

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    input:
      task: workflow.inputs.taskDescription
      context: reviewer.output.feedback
      repo: workflow.inputs.repoUrl
```

Values are CEL expressions — they can reference `workflow.inputs.*`, `env.*`, other steps' outputs, etc.

### 10.5 Workflow Output

Optional. Defines the final result of the workflow, accessible by the caller (CLI, API, parent workflow) as `workflow.output`.

**If `output` is not defined, the workflow output is the output of the last executed step.**

Single value mapping:

```yaml
output: reviewer.output.summary
```

Structured mapping:

```yaml
output:
  approved: reviewer.output.approved
  code: coder.output.code
  summary: reviewer.output.summary
```

With schema (return validation):

```yaml
output:
  schema:
    approved:
      type: boolean
      required: true
    code:
      type: string
    summary:
      type: string
  map:
    approved: reviewer.output.approved
    code: coder.output.code
    summary: reviewer.output.summary
```

### 10.6 Participant Output

Each **named** participant (reusable or named inline) produces output accessible as `<step>.output`. Without schema, it is a string. The runtime attempts automatic parsing:

1. If the output is valid JSON → accessible as a map (`coder.output.field`)
2. If not → accessible as a string (`coder.output`)

Anonymous inline participants also produce output, but it is only accessible via the implicit I/O chain (see [10.7](#107-implicit-io-chain)).

With explicit schema on the participant:

```yaml
participants:
  reviewer:
    type: exec
    run: ./review.sh
    output:
      approved:
        type: boolean
        required: true
      comments:
        type: string
      score:
        type: integer
        minimum: 0
        maximum: 10
```

When schema is defined, the runtime validates the step's output. Validation failure is treated as an error and follows the `onError` strategy.

### 10.7 Implicit I/O Chain

The output of each step is implicitly passed as input to the **next sequential step**, forming a chain analogous to Unix pipes. The chained value is accessible to the receiving participant via its `input` variable.

```yaml
flow:
  # Anonymous step — output chains to the next step
  - type: exec
    run: curl -s https://api.example.com/data

  # Named step — receives chained input, addressable by name
  - as: processor
    type: exec
    run: ./process.sh    # input contains the curl output

  # Anonymous step — receives processor's output via chain
  - type: http
    url: https://api.example.com/result
    method: POST
    body: input
```

#### Chain + Explicit Input Merge

When a participant has both a chained input (from the previous step) and an explicit `input` mapping, the runtime attempts to merge them:

- **Map + map**: merged. Explicit mapping keys take precedence on conflict.
- **String + string**: explicit mapping takes precedence.
- **Incompatible types** (e.g., string + map): runtime error.

#### Chain Behavior in Control Flow

- **`if`/`then`/`else`**: The chained output after an `if` block is the output of the last step in whichever branch executed. If the condition is false and no `else` branch exists, the chain passes through unchanged.
- **`loop`**: The chained output after a `loop` is the output of the last step of the last iteration.
- **`parallel`**: The chained output after a `parallel` block is an **array** of outputs from all branches, in declaration order. Only named steps are included as named entries; anonymous outputs are included positionally.

#### Anonymous Participants in Control Flow

- **`if`/`then`/`else` and `loop`**: Anonymous participants are permitted. The chain operates linearly within each branch or iteration.
- **`parallel`**: Anonymous participants are permitted, but their output is only included positionally in the output array. Since there is no "next step" within a parallel branch, the anonymous output is only meaningful as part of the aggregated result.

### 10.8 Precedence Summary

```
Nothing defined       → string in, string out (chain passthrough)
Chain only            → previous step output becomes input
Explicit mapping only → CEL expressions resolve input
Chain + explicit      → merge (explicit takes precedence on conflict)
With schema           → validation via JSON Schema
```

---

## 11. Expressions

All expressions in the workflow (conditions, guards, input mappings, output mappings) use **Google CEL (Common Expression Language)**.

### 11.1 Why CEL

CEL is a non-Turing-complete expression language created by Google for safe, fast evaluation in declarative configurations. It was chosen for this DSL for the following reasons:

**Runtime-agnostic.** Official implementations exist in Go (`google/cel-go`), with community libraries in Rust and JavaScript. This aligns with the DSL's principle of not being tied to any specific runtime language.

**Sandboxed by design.** CEL has no I/O, no infinite loops, no side effects. An expression cannot read files, make network calls, or modify state. It can only evaluate data that is explicitly provided to it.

**Type-checked at parse time.** Type errors are detected before execution. A condition like `retries > "three"` (comparing int to string) fails at parse time, not at runtime in the middle of a workflow.

**Familiar syntax.** CEL looks like C/JS/Python. Developers already know how to read `approved == false && retries < 3`. There is no new syntax to learn for 90% of use cases.

**Industry adoption.** CEL is used in Kubernetes admission policies, Google Cloud IAM conditions, Firebase security rules, and Envoy proxy configurations. It is not an obscure choice — it is a battle-tested standard for exactly this use case.

Alternatives considered and rejected:

- **`eval()` / JavaScript expressions** — Ties the spec to a single runtime language. JS semantics (truthiness, type coercion, `==` vs `===`) leak into the DSL. Security surface is large even with sandboxing (`vm2`, `isolated-vm`).
- **Custom mini-DSL** — Portable, but every function (string operations, list comprehensions, type conversions) becomes an implementation task. CEL provides all of this out of the box.
- **JSONPath / JMESPath** — Good for data queries, poor for logic. `&&`, `||`, and comparison operators are either missing or awkward.

Reference: https://cel.dev / https://github.com/google/cel-spec

### 11.2 Standard Functions

CEL comes with a comprehensive standard library. These functions are available in any expression within the workflow:

**Strings:**
`contains`, `startsWith`, `endsWith`, `matches` (regex, RE2 syntax), `size`, `lowerAscii`, `upperAscii`, `replace`, `split`, `join`

**Lists and Maps:**
`size`, `in`, `+` (concatenation), `[]` (index/key access)

**Macros:**
`has` (field existence), `all`, `exists`, `exists_one`, `filter`, `map`

**Type conversions:**
`int()`, `uint()`, `double()`, `string()`, `bool()`, `bytes()`, `timestamp()`, `duration()`

**Timestamp / Duration:**
Operations with `timestamp()` and `duration()`, temporal comparisons, component access (`.getFullYear()`, `.getHours()`, etc.)

### 11.3 Examples in Workflow Context

```yaml
# Simple condition
- if:
    condition: reviewer.output.approved == false

# Combined logic
- if:
    condition: reviewer.output.approved == false && coder.retries < 3

# String match
- if:
    condition: coder.output.language.contains("python")

# Field existence check
- if:
    condition: has(reviewer.output.comments)

# Temporal comparison
- if:
    condition: timestamp(workflow.startedAt) + duration("30m") < now

# List operations
- if:
    condition: results.all(r, r.score > 7) && !results.exists(r, r.level == "critical")

# Step guard with string function
- deploy:
    when: coder.output.target.endsWith(".production")
```

---

## 12. Runtime Variables

Variables available in any CEL expression within the workflow. Accessed as direct identifiers — no `$` prefix, no `steps.` prefix.

### 12.1 `workflow` — Definition and I/O Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `workflow.id` | string | Identifier of the workflow definition |
| `workflow.name` | string | Human-readable name |
| `workflow.version` | string | Version of the definition |
| `workflow.inputs` | map | Workflow input parameters, as defined in the `inputs` field |
| `workflow.output` | string, map | Workflow output, as defined in the `output` field |

### 12.2 `execution` — Current Run Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `execution.id` | string | Unique ID of this execution (run) |
| `execution.number` | int | Sequential execution number |
| `execution.startedAt` | timestamp | When the execution started |
| `execution.status` | string | Current status: `running`, `success`, `failure` |
| `execution.context` | map | Shared data between steps (read/write scratchpad) |
| `execution.cwd` | string | Base working directory resolved at startup |

`execution.context` is a read/write map that any step can use to share data across the workflow. It functions as a global scratchpad for the execution — any step can read from and write to it.

`execution.cwd` is the base working directory for the execution, resolved from the precedence chain: `--cwd` (CLI flag) > `defaults.cwd` > process cwd. Individual participants may override this with their own `cwd` field.

### 12.3 `input` — Current Participant Input

The resolved input for the currently executing participant. This includes both the implicit chain value (see [I/O Chain](#107-implicit-io-chain)) and any explicit input mapping, merged per the rules in [10.7](#107-implicit-io-chain).

Read-only from the participant's perspective.

```yaml
# Accessing participant's own input
participants:
  coder:
    type: exec
    run: ./code.sh
    input:
      task: workflow.inputs.taskDescription
      repo: workflow.inputs.repoUrl
```

```
# Inside coder's execution context:
input.task          # the resolved task description
input.repo          # the resolved repo URL
```

**Note:** `input` is NOT `workflow.inputs`. To access workflow-level inputs, use `workflow.inputs.*`.

### 12.4 `output` — Current Participant Output

The output produced by the currently executing participant. Write-only; set by the runtime after execution completes.

### 12.5 `env` — Environment Variables

```
env.API_KEY
env.NODE_ENV
```

Injected by the runtime, never defined in the YAML (security). Read-only access.

### 12.6 `<step>` — Participant Result (Direct Access by Name)

Each **named** participant (reusable or named inline) is accessible directly by its name (no `steps.` prefix). Access always returns data from the **last execution** of that step.

| Variable | Type | Description |
|----------|------|-------------|
| `<step>.status` | string | `success`, `failure`, `skipped` |
| `<step>.output` | string or map | Free-form object returned by the step |
| `<step>.startedAt` | timestamp | When the step started |
| `<step>.finishedAt` | timestamp | When the step finished |
| `<step>.duration` | duration | Execution time |
| `<step>.retries` | int | How many times the step executed |
| `<step>.error` | string | Error message (when `status == "failure"`) |
| `<step>.cwd` | string | Effective working directory used (only for `exec` participants) |

This design choice — direct access by name instead of a `steps.` prefix — was made for DX reasons. `reviewer.output.approved` is more natural and less verbose than `steps.reviewer.output.approved`. The tradeoff is that participant names share the namespace with reserved variables, which is enforced at parse time.

Anonymous inline participants are NOT addressable via this mechanism — their output is only accessible via the implicit I/O chain.

### 12.7 `loop` — Iteration Context

Available only inside `loop:` blocks. Can be renamed using `as`.

| Variable | Type | Description |
|----------|------|-------------|
| `loop.index` | int | 0-based iteration index |
| `loop.iteration` | int | 1-based iteration number |
| `loop.first` | bool | `true` if this is the first iteration |
| `loop.last` | bool | `true` if this is the last iteration (only when `max` is defined) |

Within a loop, step outputs are overwritten on each iteration — they always reflect the most recent execution.

### 12.8 `event` — Event Payload (Wait Context)

Available only inside `wait:` blocks when waiting for an event.

| Variable | Type | Description |
|----------|------|-------------|
| `event` | map | The received event payload |

### 12.9 `now` — Current Timestamp

Available in any expression.

| Variable | Type | Description |
|----------|------|-------------|
| `now` | timestamp | Current timestamp at evaluation time |

### 12.10 Variable Summary

```
workflow.*              definition metadata
workflow.inputs.*       workflow input parameters
workflow.output         workflow output
execution.*             execution metadata (includes execution.cwd)
execution.context.*     shared data (scratchpad)
input                   current participant input (chain + explicit, merged)
output                  current participant output (write-only)
env.*                   environment variables
<step>.*                named participant result (includes <step>.cwd for exec)
loop.*                  iteration context (or renamed via 'as')
event                   event payload (in wait blocks)
now                     current timestamp
```

---

## 13. Comparisons

### 13.1 The Same Scenario Across Tools

To illustrate the DX difference, here is the same workflow implemented in duckflux and competing tools. The scenario: a coder implements, a reviewer reviews, if not approved repeat up to 3 times, then deploy if approved.

#### duckflux (~10 lines of flow)

```yaml
flow:
  - loop:
      until: reviewer.output.approved == true
      max: 3
      steps:
        - coder
        - reviewer
  - if:
      condition: reviewer.output.approved == true
      then:
        - deploy
```

Participants are defined separately (or inline). The flow itself is linear, readable, and self-contained.

#### Argo Workflows (~40 lines)

```yaml
steps:
  - - name: bc
      template: bc-iteration
  - - name: recurse
      template: bc-loop
      when: >-
        {{steps.bc.outputs.parameters.approved}} == "false" &&
        {{inputs.parameters.iteration}} < 3
      arguments:
        parameters:
          - name: iteration
            value: "{{=asInt(inputs.parameters.iteration) + 1}}"
```

Requires template recursion, manual iteration counters, and string-interpolated type casting. The developer must understand three separate concepts (templates, parameter passing, expression syntax) to read a simple loop.

#### GitHub Actions (~50+ lines)

GitHub Actions has no conditional loop construct. The workaround is to unroll iterations manually with `if` guards on each step, or use recursive reusable workflows in separate files. The deploy condition becomes a monstrous OR chain across all possible reviewer outputs.

#### n8n (~70 lines JSON)

n8n has no loop primitive. The workaround requires a JavaScript Function node for iteration counting, an IF node for control flow, and circular node connections. The reference syntax `$node['Reviewer'].json.approved` is verbose and fragile. The visual editor makes it intuitive, but the exported JSON spec is unreadable.

#### Temporal (~35 lines Go)

```go
for i := 0; i < 3; i++ {
    err := workflow.ExecuteActivity(ctx, CoderActivity, ...).Get(ctx, &coderOutput)
    // ...
    if reviewerOutput.Approved { break }
}
```

Clear for Go developers, but it is code — not a spec. Requires compilation, worker deployment, and a Temporal server.

#### Airflow (impossible natively)

Airflow DAGs are acyclic by definition. Conditional loops are architecturally impossible without sub-DAGs or the DAG triggering itself recursively.

### 13.2 Comparative Summary

| Feature | duckflux | Argo | GHA | n8n | Temporal | Airflow |
|---------|---------|------|-----|-----|----------|---------|
| Conditional loop | native | template recursion | unroll | JS hack | code | impossible |
| Fixed loop | native | native | no | JS hack | code | no |
| Parallelism | native | native | jobs | visual | goroutines | native |
| Conditional branch | native | when | if | IF node | code | BranchOperator |
| Guard (when) | native | when | if per step | no | code | no |
| Events (emit/wait) | native | no | no | webhook node | signals | sensors |
| Error handling | onError + retry + fallback | retryStrategy | continue-on-error | no | code | no |
| Timeout | global + per-step | per-step | per-job | per-node | per-activity | per-task |
| Sub-workflows | native | template ref | reusable workflows | sub-workflow node | child workflow | SubDagOperator |
| Inline participants | native | no | no | no | no | no |
| Spec is readable | yes | partially | partially | no (JSON) | no (code) | no (Python) |

---

## 14. Complete Example

A full workflow demonstrating multiple features together:

```yaml
id: code-review-pipeline
name: Code Review Pipeline
version: 1

defaults:
  timeout: 10m
  cwd: ./repo

inputs:
  repoUrl:
    type: string
    format: uri
    required: true
    description: "Repository URL to work on"
  branch:
    type: string
    default: "main"
  maxReviewRounds:
    type: integer
    default: 3
    minimum: 1
    maximum: 10

participants:
  coder:
    type: exec
    as: "Code Builder"
    run: ./code.sh
    timeout: 15m
    onError: retry
    retry:
      max: 2
      backoff: 5s
    input:
      repo: workflow.inputs.repoUrl
      branch: workflow.inputs.branch

  reviewer:
    type: exec
    as: "Code Reviewer"
    run: ./review.sh
    timeout: 10m
    onError: fail
    output:
      approved:
        type: boolean
        required: true
      comments:
        type: string
      score:
        type: integer
        minimum: 0
        maximum: 10

flow:
  - coder

  - loop:
      as: round
      until: reviewer.output.approved == true
      max: workflow.inputs.maxReviewRounds
      steps:
        - reviewer
        - coder:
            when: reviewer.output.approved == false

  - parallel:
      - as: tests
        type: exec
        run: npm test
        timeout: 5m
        onError: skip

      - as: lint
        type: exec
        run: npm run lint
        timeout: 2m
        onError: skip

  - if:
      condition: tests.status == "success" && lint.status == "success"
      then:
        - as: deploy
          type: exec
          run: ./deploy.sh
          timeout: 5m

        - as: notifySuccess
          type: emit
          event: "deploy.completed"
          payload:
            approved: reviewer.output.approved
            score: reviewer.output.score
      else:
        - as: notifyFailure
          type: emit
          event: "deploy.failed"
          payload:
            tests: tests.status
            lint: lint.status

output:
  approved: reviewer.output.approved
  score: reviewer.output.score
  testResult: tests.status
  lintResult: lint.status
```

---

## 15. Tooling

### 15.1 JSON Schema

A JSON Schema for the duckflux format is provided at `duckflux.schema.json`. It enables editor-level validation and autocomplete without requiring any custom tooling.

**VS Code setup** — add to `.vscode/settings.json`:

```json
{
  "yaml.schemas": {
    "./duckflux.schema.json": "*.flow.yaml"
  }
}
```

This gives you red squiggles on invalid fields, autocomplete on participant types (`agent`, `exec`, `http`, ...), and validation of durations, retry configs, and flow constructs — all for free via the [YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml).

**What the schema validates:**

- Top-level structure (`id`, `name`, `participants`, `flow`, `inputs`, `output`, `defaults`)
- Participant types and their type-specific fields
- Reserved participant names (`workflow`, `execution`, `input`, `output`, `env`, `loop`, `event`)
- Flow constructs (`loop`, `parallel`, `if`, `wait`, `when` guards, inline participants, participant overrides)
- Loop requires at least `until` or `max`
- Duration format (`30s`, `5m`, `2h`, `1d`)
- Retry config structure
- Input schema fields (JSON Schema subset)
- Emit payload format
- Wait modes (event, timeout, until)

**What the schema does NOT validate** (requires a linter or runtime):

- CEL expression syntax and type correctness
- Cross-references (participant in flow exists in `participants`)
- `onError` redirect targets exist
- Sub-workflow file paths resolve
- Circular dependencies

### 15.2 Tooling Roadmap

| Phase | Tool | Purpose |
|-------|------|---------|
| v1 | JSON Schema | Editor validation + autocomplete via YAML extension |
| v1.5 | CLI linter (`duckflux lint`) | Structural validation, cross-reference checks, CEL parse |
| v2 | Language Server (LSP) | Contextual autocomplete, go-to-definition, hover docs, real-time diagnostics |

---

## 16. Roadmap (v2+)

Features deliberately out of scope for v0.3. Deferred to future versions based on real-world demand:

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

---

## 17. Decisions Log

Decisions made during the design of this spec, with rationale:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Expression language | Google CEL | Runtime-agnostic (Go, Rust, JS), sandboxed, type-checked at parse time, familiar syntax. |
| Variable access | Direct by name (`reviewer.output`) | Better DX than `steps.reviewer.output`. Tradeoff: shared namespace with reserved words. |
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

---

*Version 0.3 — March 2026*