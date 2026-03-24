# Duckflux Workflow Specification

**Version:** 0.6
**Status:** Draft

## 1. Introduction

This document defines the Duckflux Workflow DSL — a declarative, runtime-agnostic YAML-based domain-specific language for orchestrating workflows. A conforming runtime MUST implement the semantics described in this specification.

### 1.1 Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.ietf.org/rfc/rfc2119.txt).

### 1.2 Notation

- **CEL** refers to the Common Expression Language as defined in https://github.com/google/cel-spec.
- **JSON Schema** refers to the JSON Schema specification (https://json-schema.org/).
- Duration literals use the format `<number><unit>`, where unit is one of: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).

---

## 2. Document Structure

A Duckflux workflow is a YAML document with the following top-level fields:

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `version` | no | string | Specification version. Default: `"0.6"`. |
| `id` | no | string | Unique identifier for the workflow definition. |
| `name` | no | string | Human-readable name. |
| `defaults` | no | object | Global defaults applied to all participants. |
| `inputs` | no | object | Input parameters the workflow accepts. |
| `participants` | no | object | Named, reusable step definitions. |
| `flow` | **yes** | array | Ordered, non-empty execution sequence. |
| `output` | no | string, object | Explicit output mapping. If omitted, the output is that of the last executed step. |

A minimal valid document:

```yaml
flow:
  - type: exec
    run: echo "Hello, duckflux!"
```

A conforming parser MUST reject workflows where `flow` is an empty array.

### 2.1 Defaults

The `defaults` object MAY contain the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `timeout` | duration | Default timeout applied to all participants. |
| `cwd` | string | Default working directory for `exec` participants. |

---

## 3. Participants

A participant is the atomic unit of work in a workflow. Each participant has a `type` that determines its execution semantics.

### 3.1 Definition Modes

Participants MAY be defined in three ways:

**Reusable (in `participants` block):**

```yaml
participants:
  tests:
    type: exec
    run: npm test

flow:
  - tests
```

**Named inline (in `flow`, with `as`):**

```yaml
flow:
  - as: tests
    type: exec
    run: npm test
```

Named inline participants MUST have a unique `as` value — it MUST NOT conflict with any other inline participant name or any key in the `participants` block. Named inline participants cannot be reused elsewhere in the flow, but their results are addressable by name (see §5.6).

**Anonymous inline (in `flow`, without `as`):**

```yaml
flow:
  - type: exec
    run: echo "setup complete"
  - deploy
```

Anonymous inline participants have no addressable name. Their output is accessible only via the implicit I/O chain (see §5.7). Anonymous participants MUST NOT be referenced in CEL expressions by name.

### 3.2 Participant Types

| Type | Description |
|------|-------------|
| `exec` | Shell command execution. |
| `http` | HTTP request. |
| `mcp` | Request to an MCP server. |
| `workflow` | Reference to another workflow file. |
| `emit` | Publishes an event to the event hub. |

### 3.3 Common Fields

All participant types accept the following fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | — | **Required.** The participant type. |
| `as` | string | — | Display name. Optional for inline participants. |
| `timeout` | duration | from `defaults` | Maximum execution time. |
| `onError` | string | `"fail"` | Error handling strategy (see §6). |
| `retry` | object | — | Retry configuration (see §6.3). |
| `input` | string or object | — | Explicit input mapping (see §5.5). |
| `output` | object | — | Output schema (JSON Schema). |

### 3.4 Type-Specific Fields

#### 3.4.1 `exec`

| Field | Type | Description |
|-------|------|-------------|
| `run` | string | **Required.** Shell command to execute. |
| `cwd` | string | Working directory. Supports CEL expressions. |

##### Input Passing Semantics

How the resolved `input` value (after chain merge + explicit mapping per §5.7) is delivered to the subprocess depends on its type:

**Map input → environment variables.** When the resolved input is a map (object), each key-value pair MUST be injected as an environment variable in the subprocess environment. Keys become variable names; values are coerced to strings. The `run` command MAY reference them via standard shell interpolation (e.g., `${KEY}`). These variables are set in addition to any variables inherited from the runtime environment (`env.*` bindings).

```yaml
- as: deploy
  type: exec
  run: ./deploy.sh --branch="${BRANCH}" --env="${TARGET_ENV}"
  input:
    BRANCH: workflow.inputs.branch
    TARGET_ENV: execution.context.environment
```

**String input → stdin.** When the resolved input is a scalar string, it MUST be passed to the subprocess via standard input (stdin). This enables Unix pipe-style chaining between `exec` steps.

```yaml
flow:
  - type: exec
    run: curl -s https://api.example.com/data
  - type: exec
    run: jq '.items[] | .name'
```

In this example, the output of `curl` chains as a string to the next step, which receives it on stdin.

**No input.** When no input is available (no chain value, no explicit mapping), the subprocess MUST receive no data on stdin and MUST inherit only the runtime's own environment variables (including any `env.*` bindings). No additional environment variables are injected.

#### 3.4.2 `http`

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | **Required.** Target URL. Supports CEL expressions. |
| `method` | string | HTTP method: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. |
| `headers` | object | HTTP headers. Values support CEL expressions. |
| `body` | string or object | Request body. Supports CEL expressions. |

#### 3.4.3 `workflow`

| Field | Type | Description |
|-------|------|-------------|
| `path` | string | **Required.** Path to the sub-workflow YAML file, resolved relative to the parent workflow's directory. |

#### 3.4.4 `emit`

| Field | Type | Description |
|-------|------|-------------|
| `event` | string | **Required.** Event name to emit. |
| `payload` | string or object | Event payload. A single CEL expression or a map of CEL expressions. |
| `ack` | boolean | If `true`, block until delivery is acknowledged. Default: `false`. |
| `onTimeout` | string | Timeout behavior in acknowledged mode (`ack: true`): `fail` or `skip`. Default: `fail`. |

### 3.5 Reserved Names

The following identifiers are reserved and MUST NOT be used as participant names (neither in `participants` keys nor in `as` values):

`workflow`, `execution`, `input`, `output`, `env`, `loop`, `event`

A conforming parser MUST reject any workflow that uses a reserved name as a participant identifier.

---

## 4. Flow

The `flow` field defines the execution sequence as an ordered array. Each element MUST be one of:

- A **participant reference** (string)
- A **named inline participant** (object with `as` and `type`)
- An **anonymous inline participant** (object with `type`, without `as`)
- A **control flow construct** (`loop`, `parallel`, `if`, `wait`, `set`)
- A **participant reference with overrides** (object with participant name as key)

The `flow` array MUST contain at least one step.

### 4.1 Sequential Execution

Steps execute in top-to-bottom order. Each step completes before the next begins.

```yaml
flow:
  - stepA
  - stepB
  - stepC
```

### 4.2 Loop

Repeats a set of steps until a CEL condition evaluates to `true`, or a maximum iteration count is reached.

```yaml
flow:
  - loop:
      until: <CEL expression>
      max: <integer>
      as: <identifier>
      steps:
        - <step>
        - ...
```

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `until` | conditional | CEL expression | Exit condition. Loop terminates when this evaluates to `true`. |
| `max` | conditional | integer | Maximum number of iterations. |
| `as` | no | string | Renames the loop context variable (default: `loop`). |
| `steps` | **yes** | array | Steps to execute on each iteration. |

At least one of `until` or `max` MUST be present. If only `max` is set, the loop executes exactly N times. If only `until` is set, the loop runs until the condition is met.

Within a loop, step outputs are overwritten on each iteration and always reflect the most recent execution.

### 4.3 Parallel Execution

Executes multiple steps concurrently. The flow continues only after all parallel steps complete.

```yaml
flow:
  - parallel:
      - stepA
      - stepB
      - stepC
```

Parallel branches MAY contain inline participants (named or anonymous). Each branch element follows the same syntax rules as a top-level flow step.

### 4.4 Conditional Branching

Evaluates a CEL expression and routes execution to the matching branch.

```yaml
flow:
  - if:
      condition: <CEL expression>
      then:
        - <step>
        - ...
      else:
        - <step>
        - ...
```

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `condition` | **yes** | CEL expression | Boolean condition. |
| `then` | **yes** | array | Steps executed when the condition is `true`. |
| `else` | no | array | Steps executed when the condition is `false`. |

If `else` is omitted and the condition is `false`, execution continues to the next step after the `if` block.

### 4.5 Guard Condition (`when`)

Any step reference in the flow MAY include a `when` field — a CEL precondition. If the expression evaluates to `false`, the step is marked as `skipped` and execution continues.

```yaml
flow:
  - deploy:
      when: reviewer.output.approved == true
```

The `when` guard applies to a single step. For multi-step branching, use `if`/`then`/`else` (§4.4).

### 4.6 Wait

Pauses execution. The mode is determined by which fields are present.

#### 4.6.1 Wait for Event

```yaml
- wait:
    event: <event name>
    match: <CEL expression>
    timeout: <duration>
    onTimeout: <fail | skip>
```

The `event` variable within the `match` expression contains the received event payload.

#### 4.6.2 Wait for Duration (Sleep)

```yaml
- wait:
    timeout: <duration>
```

When only `timeout` is present with no condition, the step acts as a sleep.

#### 4.6.3 Wait for Condition (Polling)

```yaml
- wait:
    until: <CEL expression>
    poll: <duration>
    timeout: <duration>
    onTimeout: <fail | skip>
```

The `until` condition is re-evaluated at the specified `poll` interval.

**Example — wait until a specific absolute time:**

```yaml
- wait:
    until: now >= timestamp("2024-04-01T09:00:00Z")
    poll: 1m
    timeout: 48h
```

### 4.7 Flow-Level Overrides

When referencing a participant in the flow, any participant field MAY be overridden for that specific invocation:

```yaml
flow:
  - coder:
      timeout: 30m
      onError: skip
```

Flow-level overrides always take precedence over participant-level definitions.

#### 4.7.1 Input Merge on Flow Override

When a flow override specifies `input` for a participant invocation, the runtime MUST **merge** it with the participant's declared `input` instead of replacing it. Merge rules follow the chain merge semantics (§5.7):

- **map + map**: merge keys; flow override wins on conflict.
- **string + string**: flow override wins (full replace).
- **incompatible types**: runtime error.

When all three sources are present (chain + participant base input + flow override input), the merge order is:

```
chain value < participant base input < flow override input
```

Flow override has highest precedence on key conflicts, then participant base, then chain.

**Example:**

```yaml
participants:
  fetch_page:
    type: exec
    input:
      NOTION_TOKEN: execution.context.token   # base input
    run: |
      curl -sS "https://api.notion.com/v1/pages/$(cat)" \
        -H "Authorization: Bearer ${NOTION_TOKEN}"

flow:
  # resolved input = { NOTION_TOKEN: execution.context.token, PAGE_ID: workflow.inputs.story_id }
  - fetch_page:
      input:
        PAGE_ID: workflow.inputs.story_id

  - fetch_page:
      input:
        PAGE_ID: open_task.output
```

This change affects only `input` field merging. All other flow-level overrides (`timeout`, `onError`, `retry`, `when`) continue to **replace** the participant-level value.

### 4.8 Set (Context Assignment)

Writes one or more values into `execution.context`, making them available to all subsequent CEL expressions.

```yaml
flow:
  - set:
      token: workflow.inputs.api_token
      region: env.AWS_REGION
```

| Field | Type | Description |
|-------|------|-------------|
| `<key>` | CEL expression | Each key becomes `execution.context.<key>`. The value is a CEL expression evaluated at runtime. |

The `set` construct is a **flow-level control operation**, not a participant. It does not produce output and does not participate in the implicit I/O chain — the chain passes through unchanged.

Multiple keys MAY be set in a single `set` block. Keys that already exist in `execution.context` are overwritten.

A `set` key MUST NOT use a reserved name (see §3.5).

**Example — conditional assignment:**

```yaml
flow:
  - if:
      condition: has(workflow.inputs.notion_token)
      then:
        - set:
            notion_token: workflow.inputs.notion_token
      else:
        - set:
            notion_token: env.NOTION_TOKEN

  - as: fetch_pages
    type: http
    url: "'https://api.notion.com/v1/pages'"
    headers:
      Authorization: "'Bearer ' + execution.context.notion_token"
```

---

## 5. Inputs and Outputs

### 5.1 Default Data Type

All participants receive and return **string** by default. No schema is required. Schema validation is opt-in via JSON Schema.

### 5.2 Workflow Inputs

Workflow inputs are defined in the top-level `inputs` field and accessed in CEL expressions as `workflow.inputs.<field>`.

Without schema:

```yaml
inputs:
  repoUrl:
  branch:
```

All fields without a `type` are treated as `string`.

With schema (JSON Schema in YAML):

```yaml
inputs:
  repoUrl:
    type: string
    format: uri
    required: true
  branch:
    type: string
    default: "main"
  maxRetries:
    type: integer
    minimum: 1
    maximum: 10
    default: 3
```

The `required: true` shortcut within each field is syntactic sugar. A conforming parser MUST normalize it to canonical JSON Schema format (`required: [...]` at the parent object level).

### 5.3 Workflow Output

Defines the final result of the workflow, accessed in CEL expressions as `workflow.output`. If the top-level `output` field is not defined, the output of the last executed step MUST be used.

Single value:

```yaml
output: reviewer.output.summary
```

Structured:

```yaml
output:
  approved: reviewer.output.approved
  code: coder.output.code
```

With return schema validation:

```yaml
output:
  schema:
    approved:
      type: boolean
      required: true
    code:
      type: string
  map:
    approved: reviewer.output.approved
    code: coder.output.code
```

### 5.4 Participant I/O Variables

Within the execution context of a participant, the variables `input` and `output` refer to **that participant's own** input and output:

- `input` — The resolved input data received by the current participant. Read-only from the participant's perspective.
- `output` — The output produced by the current participant. Write-only; set by the runtime after execution completes.

These MUST NOT be confused with `workflow.inputs` and `workflow.output`, which refer to the workflow-level I/O.

### 5.5 Participant Explicit Input Mapping

Each participant MAY define an explicit `input` mapping via CEL expressions:

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    input: workflow.inputs.taskDescription
```

Or with structured mapping:

```yaml
participants:
  coder:
    type: exec
    run: ./code.sh
    input:
      task: workflow.inputs.taskDescription
      context: reviewer.output.feedback
```

Values MUST be CEL expressions.

### 5.6 Participant Output (Named Steps)

Each **named** participant (reusable or named inline) produces output accessible as `<step>.output`. Without schema, it is a string. The runtime SHOULD attempt automatic JSON parsing:

1. If the output is valid JSON, it MUST be accessible as a map (e.g., `coder.output.field`).
2. Otherwise, it MUST be accessible as a string (e.g., `coder.output`).

When an output schema is defined, the runtime MUST validate the step's output against it. A validation failure is treated as an error and follows the configured `onError` strategy.

### 5.7 Implicit I/O Chain

The output of each step is implicitly passed as input to the **next sequential step**. This forms a chain analogous to Unix pipes.

The chained value is accessible to the receiving participant via its `input` variable. When the participant also has an explicit `input` mapping (§5.5), the runtime MUST attempt to merge the chained value with the explicit mapping:

- If both are maps (objects), they are merged. Explicit mapping keys take precedence over chained keys on conflict.
- If both are strings, the explicit mapping takes precedence.
- If the types are incompatible (e.g., one is a string and the other is a map), the runtime MUST raise an error.

#### 5.7.1 Chain Behavior in Control Flow Constructs

**Sequential flow:** The output of step N is the chained input of step N+1.

**`if`/`then`/`else`:** The chained output after an `if` block is the output of the last step in whichever branch executed. If the condition is false and no `else` branch exists, the chain passes through unchanged from the step before the `if`.

**`loop`:** The chained output after a `loop` block is the output of the last step of the last iteration.

**`parallel`:** The chained output after a `parallel` block is an **array** containing the outputs of all parallel branches, in declaration order. Only outputs from **named** steps are included as named entries; anonymous step outputs are included positionally.

#### 5.7.2 Anonymous Participants and the Chain

Anonymous inline participants (those without `as`) produce output that is **only** accessible via the implicit chain. Their output cannot be referenced by name in CEL expressions.

```yaml
flow:
  - type: exec
    run: echo "setup data"
  - as: processor
    type: exec
    run: process.sh    # input contains "setup data"
```

#### 5.7.3 Anonymous Participants in Control Flow

- **`if`/`then`/`else` and `loop`:** Anonymous participants are permitted. The chain operates linearly within each branch or iteration.
- **`parallel`:** Anonymous participants are permitted, but their output is only included positionally in the output array. Since there is no "next step" within a parallel branch (each branch is independent), the anonymous output is only meaningful as part of the aggregated `parallel` result.

### 5.8 Precedence Summary

```
Nothing defined                          → string in, string out (chain passthrough)
Chain only                               → previous step output becomes input
Participant input only                   → CEL expressions resolve input
Flow override input only                 → CEL expressions resolve input
Participant input + flow override input  → merge (flow override wins on conflict)
Chain + participant input                → merge (participant input wins on conflict)
Chain + participant input + flow override → three-way merge (flow override > participant > chain)
With schema                              → validation via JSON Schema
```

---

## 6. Error Handling

Error handling is configurable at two levels: **participant-level** (default) and **flow-level** (per-invocation override). Flow-level always takes precedence.

### 6.1 `onError` Values

| Value | Behavior |
|-------|----------|
| `fail` | Stop the workflow immediately. This is the global default. |
| `skip` | Mark the step as `skipped` and continue. |
| `retry` | Re-execute the step per the `retry` configuration. |
| `<participant>` | Redirect execution to the named participant as a fallback. |

When `onError` references another participant name, that participant MUST exist in the `participants` block.

### 6.2 Precedence

```
flow-level onError > participant-level onError > global default (fail)
```

### 6.3 Retry Configuration

```yaml
retry:
  max: <integer>       # Required when onError: retry. Maximum attempts.
  backoff: <duration>  # Interval between attempts. Default: 0s.
  factor: <number>     # Backoff multiplier. Default: 1 (constant).
```

With `backoff: 2s` and `factor: 2`, the intervals are: 2s, 4s, 8s, etc.

---

## 7. Timeout

Timeout limits execution time for a step. It is configurable at three levels:

| Level | Example |
|-------|---------|
| Global default | `defaults: { timeout: 5m }` |
| Participant-level | `timeout: 15m` on the participant definition |
| Flow-level | `timeout: 30m` as a flow override |

### 7.1 Precedence

```
flow-level > participant-level > defaults > runtime default (no timeout)
```

When a step exceeds its timeout, it is treated as a failure and follows the configured `onError` strategy.

---

## 8. Working Directory

The `cwd` field sets the working directory for `exec` participants. It supports CEL expressions.

### 8.1 Precedence

```
participant.cwd > defaults.cwd > CLI --cwd > process cwd
```

---

## 9. Sub-Workflows

Workflows MAY reference other `.yaml` files as steps using `type: workflow`.

### 9.1 Definition Modes

**As a reusable participant (declared in `participants`):**

```yaml
participants:
  reviewCycle:
    type: workflow
    path: ./review-loop.yaml
    input:
      repo: workflow.inputs.repoUrl
```

**As an inline step in `flow`:**

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

### 9.2 Semantics

- Sub-workflows MUST have their own isolated `execution.context`.
- `onError` and `timeout` from the parent apply to the sub-workflow as a whole.
- The sub-workflow's `output` is accessible as `<step>.output` in the parent.
- Sub-workflows MAY be arbitrarily nested.
- Paths MUST be resolved relative to the parent workflow's directory.

---

## 10. Events

Duckflux supports event-driven communication through `emit` (publish) and `wait` (subscribe).

### 10.1 Emitting Events

The `emit` participant type publishes an event to the event hub.

**Fire-and-forget** (default): dispatches the event and continues immediately.

**Acknowledged** (`ack: true`): blocks until the event hub confirms delivery.

In acknowledged mode, the participant `timeout` controls how long to wait for delivery acknowledgment. If timeout is reached, `onTimeout` applies:

- `fail` (default): fail the step.
- `skip`: mark the step as `skipped` and continue.

```yaml
- as: notify
  type: emit
  event: "deploy.started"
  payload: deploy.output
  ack: true
  timeout: 10s
  onTimeout: skip
```

### 10.2 Payload Format

A single CEL expression:

```yaml
payload: coder.output
```

A structured object with CEL expression values:

```yaml
payload:
  taskId: workflow.inputs.taskId
  status: coder.output.status
```

### 10.3 Waiting for Events

See §4.6.1.

### 10.4 Internal Propagation

Events emitted via `emit` MUST also be propagated internally within the workflow. A `wait` step MAY react to events emitted by earlier steps in the same workflow.

---

## 11. Expressions

All expressions in a Duckflux workflow (conditions, guards, input/output mappings) MUST use **Google CEL** (Common Expression Language) as defined in https://github.com/google/cel-spec.

### 11.1 Standard Library

A conforming runtime MUST support the CEL standard library, including:

- **Strings:** `contains`, `startsWith`, `endsWith`, `matches` (RE2), `size`, `lowerAscii`, `upperAscii`, `replace`, `split`, `join`
- **Lists and Maps:** `size`, `in`, `+` (concatenation), `[]` (index/key access)
- **Macros:** `has`, `all`, `exists`, `exists_one`, `filter`, `map`
- **Type conversions:** `int()`, `uint()`, `double()`, `string()`, `bool()`, `bytes()`, `timestamp()`, `duration()`
- **Timestamp/Duration:** arithmetic with `timestamp()` and `duration()`, temporal comparisons, component access

---

## 12. Runtime Variables

The following variables MUST be available in any CEL expression within a workflow.

### 12.1 `workflow` — Definition and I/O Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `workflow.id` | string | Workflow definition identifier. |
| `workflow.name` | string | Human-readable name. |
| `workflow.version` | string | Definition version. |
| `workflow.inputs` | map | Workflow input parameters, as defined in the `inputs` field. |
| `workflow.output` | string, map | Workflow output, as defined in the `output` field. |

### 12.2 `execution` — Current Run Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `execution.id` | string | Unique identifier for this execution. |
| `execution.number` | int | Sequential execution number. |
| `execution.startedAt` | timestamp | Execution start time. |
| `execution.status` | string | Current status: `running`, `success`, `failure`. |
| `execution.context` | map | Read/write shared data scratchpad. |
| `execution.cwd` | string | Resolved base working directory. |

### 12.3 `input` — Current Participant Input

The resolved input for the currently executing participant. This includes both the implicit chain value (§5.7) and any explicit input mapping (§5.5), merged per the rules in §5.7.

Read-only from the participant's perspective.

### 12.4 `output` — Current Participant Output

The output produced by the currently executing participant. Write-only; set by the runtime after execution completes.

### 12.5 `env` — Environment Variables

Injected by the runtime. MUST NOT be defined in the YAML. Read-only.

```
env.API_KEY
env.NODE_ENV
```

### 12.6 `<step>` — Participant Result

Each **named** participant (reusable or named inline) is accessible directly by its name. Access returns data from the **last execution** of that step.

| Variable | Type | Description |
|----------|------|-------------|
| `<step>.status` | string | `success`, `failure`, `skipped` |
| `<step>.output` | string or map | Step output. |
| `<step>.startedAt` | timestamp | Step start time. |
| `<step>.finishedAt` | timestamp | Step end time. |
| `<step>.duration` | duration | Execution duration. |
| `<step>.retries` | int | Number of executions. |
| `<step>.error` | string | Error message (when `status == "failure"`). |
| `<step>.cwd` | string | Effective working directory (only for `exec`). |

Anonymous inline participants are NOT addressable via this mechanism.

### 12.7 `loop` — Iteration Context

Available only inside `loop` blocks. The identifier MAY be renamed via the `as` field.

| Variable | Type | Description |
|----------|------|-------------|
| `loop.index` | int | 0-based iteration index. |
| `loop.iteration` | int | 1-based iteration number. |
| `loop.first` | bool | `true` on the first iteration. |
| `loop.last` | bool | `true` on the last iteration (only when `max` is defined). |

### 12.8 `event` — Event Payload

Available only inside `wait` blocks when waiting for an event. Contains the received event payload as a map.

### 12.9 `now` — Current Timestamp

Available in any expression. Returns the current timestamp at evaluation time.

### 12.10 Summary

```
workflow.*              Definition metadata
workflow.inputs.*       Workflow input parameters
workflow.output         Workflow output
execution.*             Execution metadata
execution.context.*     Shared data scratchpad (writable via `set` construct)
input                   Current participant input (chain + explicit, merged)
output                  Current participant output (write-only)
env.*                   Environment variables
<step>.*                Named participant result
loop.*                  Iteration context (or renamed via 'as')
event                   Event payload (in wait blocks)
now                     Current timestamp
```

---

## 13. Validation

### 13.1 Static Validation (Parser)

A conforming parser MUST validate:

- Top-level document structure
- `flow` is a non-empty array
- Participant types and their required type-specific fields
- Reserved participant name violations
- Inline participant name uniqueness (no `as` conflicts with `participants` keys or other inline `as` values)
- Flow construct structure (`loop`, `parallel`, `if`, `wait`, `set`)
- `loop` requires at least one of `until` or `max`
- Duration literal format
- Retry configuration structure

### 13.2 Semantic Validation (Linter/Runtime)

A conforming runtime SHOULD validate:

- CEL expression syntax and type correctness
- Participant cross-references (flow references exist in `participants`)
- `onError` redirect targets exist
- Sub-workflow file paths resolve
- Absence of circular dependencies
- I/O chain merge compatibility (§5.7)
- `set` keys are not reserved names

---

## Appendix A: Complete Example

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

## Appendix B: Anonymous Participant Example

```yaml
flow:
  # Anonymous step — output chains to the next step
  - type: exec
    run: curl -s https://api.example.com/data

  # Named step — receives chained input, addressable by name
  - as: processor
    type: exec
    run: ./process.sh

  # Anonymous step — receives processor's output via chain
  - type: http
    url: https://api.example.com/result
    method: POST
    body: input
```
