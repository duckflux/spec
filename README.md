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
participants:
  stepA:
    type: exec

flow:
  - stepA
```

### 3.1 Top-level Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Human-readable workflow name |
| `version` | no | Version identifier for the workflow definition |
| `defaults` | no | Global defaults (timeout, etc.) applied to all participants |
| `inputs` | no | Input parameters the workflow accepts from its caller |
| `participants` | yes | Named steps that can be referenced in the flow |
| `flow` | yes | The execution sequence — the core of the workflow |
| `output` | no | Explicit output mapping. If omitted, output is the last executed step's output |

---

## 4. Participants

Participants are the named, reusable building blocks of a workflow. Each participant has a `type` that determines its behavior, and a set of configuration fields that vary by type.

```yaml
participants:
  builder:
    type: agent
    model: claude-sonnet-4-20250514
    tools: [read, write, bash]

  tests:
    type: exec
    run: npm test

  notify:
    type: http
    url: https://hooks.slack.com/services/...
    method: POST
```

### 4.1 Participant Types

| Type | Description |
|------|-------------|
| `agent` | Autonomous agent that executes tasks using a language model and configured tools. |
| `exec` | Terminal command execution. Useful for tests, linting, builds, deploys, and any shell operation. |
| `http` | HTTP request. Useful for API integration, webhooks, and external service calls. |
| `human` | Manual task performed by a human. Useful for approvals, manual reviews, and quality gates. |
| `mcp` | Request to another MCP server. Useful for delegating tasks across different MCPs or organizations. |
| `workflow` | Reference to another workflow file. Enables composition and reuse. See [Sub-workflows](#8-sub-workflows-composition). |
| `hook` | External event gateway for webhooks, CI/CD notifications, and bidirectional communication. Full implementation deferred to v2 (depends on signals). |

### 4.2 Common Participant Fields

These fields are available on all participant types:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | — | Required. The participant type. |
| `as` | string | — | Optional human-readable display name. |
| `timeout` | duration | from `defaults` | Maximum execution time before the step is treated as a failure. |
| `onError` | string | `fail` | Error handling strategy. See [Error Handling](#6-error-handling). |
| `retry` | object | — | Retry configuration. Only applies when `onError: retry`. |
| `input` | string or map | — | Input mapping from workflow data to this participant. |
| `output` | map | — | Output schema definition (JSON Schema, opt-in). |

### 4.3 Reserved Names

Participant names share the same namespace as runtime variables. The following names are reserved and cannot be used as participant names:

`workflow`, `execution`, `input`, `output`, `env`, `loop`

The parser must reject workflows that use reserved names as participant identifiers.

---

## 5. Flow Syntax

The `flow` key defines the execution sequence. It is an ordered list of steps, where each step is either a participant reference or a control flow construct.

### 5.1 Sequential Execution

Steps execute top-to-bottom, one at a time. The simplest possible flow:

```yaml
flow:
  - stepA
  - stepB
  - stepC
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

### 5.7 Flow-level Overrides

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
    type: agent
    model: claude-sonnet-4-20250514
    tools: [read, write]
    onError: retry
    retry:
      max: 3
      backoff: 2s

  reviewer:
    type: agent
    model: claude-sonnet-4-20250514
    tools: [read]
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
    type: agent
    onError: fixer

  fixer:
    type: agent
    tools: [read, write, bash]

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

## 7. Timeout

Timeout prevents steps from blocking the workflow indefinitely. It is configurable at three levels with clear precedence.

### 7.1 Global Default

```yaml
defaults:
  timeout: 5m
```

Applies to all steps that do not define their own timeout.

### 7.2 Participant-level

```yaml
participants:
  coder:
    type: agent
    timeout: 15m

  deploy:
    type: exec
    run: ./deploy.sh
    timeout: 2m
```

### 7.3 Flow-level Override

```yaml
flow:
  - coder:
      timeout: 30m
  - reviewer
```

### 7.4 Precedence

```
flow > participant > defaults > runtime default (no timeout)
```

When a step exceeds its timeout, it is treated as a failure and follows the configured `onError` strategy.

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
      repo: input.repoUrl
      branch: input.branch

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
  - reviewCycle:
      workflow: ./review-loop.yaml
      input:
        repo: input.repoUrl
  - deploy
```

### 8.3 Behavior

- Sub-workflows have their own `execution.context` (isolated from the parent).
- `onError` and `timeout` from the parent participant apply to the sub-workflow as a whole.
- The `output` defined in the sub-workflow is mapped as `<step>.output` in the parent workflow.
- Sub-workflows can be nested (workflow calls workflow calls workflow).

---

## 9. Inputs and Outputs

### 9.1 Core Principle: String by Default

Every participant, by default, receives and returns **string**. No schema required. Input is a string, output is a string — like stdin/stdout. This allows any content type: plain text, JSON, XML, binary, or anything else.

Schema is **opt-in**. When defined, it uses JSON Schema (written in YAML) for validation and documentation.

### 9.2 Workflow Inputs

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

### 9.3 Participant Inputs

Each participant can map data from the workflow to its inputs. Without schema, it is direct string passthrough:

```yaml
participants:
  coder:
    type: agent
    input: input.taskDescription
```

With structured mapping:

```yaml
participants:
  coder:
    type: agent
    input:
      task: input.taskDescription
      context: reviewer.output.feedback
      repo: input.repoUrl
```

Values are CEL expressions — they can reference `input.*`, `env.*`, other steps, etc.

### 9.4 Workflow Output

Optional. Defines the final result of the workflow, accessible by the caller (CLI, API, parent workflow).

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

### 9.5 Participant Output

Each participant produces output accessible as `<step>.output`. Without schema, it is a string. The runtime attempts automatic parsing:

1. If the output is valid JSON → accessible as a map (`coder.output.field`)
2. If not → accessible as a string (`coder.output`)

With explicit schema on the participant:

```yaml
participants:
  reviewer:
    type: agent
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

### 9.6 Precedence Summary

```
Nothing defined       → string in, string out
Mapping only          → data passthrough, no validation
With schema           → validation via JSON Schema
```

---

## 10. Expressions

All expressions in the workflow (conditions, guards, input mappings, output mappings) use **Google CEL (Common Expression Language)**.

### 10.1 Why CEL

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

### 10.2 Standard Functions

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

### 10.3 Examples in Workflow Context

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

## 11. Runtime Variables

Variables available in any CEL expression within the workflow. Accessed as direct identifiers — no `$` prefix, no `steps.` prefix.

### 11.1 `workflow` — Definition Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `workflow.id` | string | Identifier of the workflow definition |
| `workflow.name` | string | Human-readable name |
| `workflow.version` | string | Version of the definition |

### 11.2 `execution` — Current Run Metadata

| Variable | Type | Description |
|----------|------|-------------|
| `execution.id` | string | Unique ID of this execution (run) |
| `execution.number` | int | Sequential execution number |
| `execution.startedAt` | timestamp | When the execution started |
| `execution.status` | string | Current status: `running`, `success`, `failure` |
| `execution.context` | map | Shared data between steps (read/write scratchpad) |

`execution.context` is a read/write map that any step can use to share data across the workflow. It functions as a global scratchpad for the execution — any step can read from and write to it.

### 11.3 `input` — Workflow Input Parameters

Defined by the workflow author, typed and accessed directly:

```yaml
inputs:
  repoUrl: string
  branch: string
  verbose: bool
```

```
# usage in expressions
input.repoUrl.contains("github.com") && input.verbose == true
```

### 11.4 `output` — Workflow Output (Optional)

Defines the final result of the workflow, accessible by the caller. If not defined, the output of the last executed step is used. See [Workflow Output](#94-workflow-output) for mapping details.

### 11.5 `env` — Environment Variables

```
env.API_KEY
env.NODE_ENV
```

Injected by the runtime, never defined in the YAML (security). Read-only access.

### 11.6 `<step>` — Participant Result (Direct Access by Name)

Each registered participant is accessible directly by its name (no `steps.` prefix). Access always returns data from the **last execution** of that step.

| Variable | Type | Description |
|----------|------|-------------|
| `<step>.status` | string | `success`, `failure`, `skipped` |
| `<step>.output` | map | Free-form object returned by the step |
| `<step>.startedAt` | timestamp | When the step started |
| `<step>.finishedAt` | timestamp | When the step finished |
| `<step>.duration` | duration | Execution time |
| `<step>.retries` | int | How many times the step executed |
| `<step>.error` | string | Error message (when `status == "failure"`) |

This design choice — direct access by name instead of a `steps.` prefix — was made for DX reasons. `reviewer.output.approved` is more natural and less verbose than `steps.reviewer.output.approved`. The tradeoff is that participant names share the namespace with reserved variables, which is enforced at parse time.

### 11.7 `loop` — Iteration Context

Available only inside `loop:` blocks.

| Variable | Type | Description |
|----------|------|-------------|
| `loop.index` | int | 0-based iteration index |
| `loop.iteration` | int | 1-based iteration number |
| `loop.first` | bool | `true` if this is the first iteration |
| `loop.last` | bool | `true` if this is the last iteration (only when `max` is defined) |

Within a loop, step outputs are overwritten on each iteration — they always reflect the most recent execution.

### 11.8 Variable Summary

```
workflow.*              definition metadata
execution.*             execution metadata
execution.context.*     shared data (scratchpad)
input.*                 input parameters
output                  workflow output (optional)
env.*                   environment variables
<step>.*                participant result (last execution)
loop.*                  iteration context
```

---

## 12. Comparisons

### 12.1 The Same Scenario Across Tools

To illustrate the DX difference, here is the same workflow implemented in duckflux and competing tools. The scenario: a coder implements, a reviewer reviews, if not approved repeat up to 3 times, then deploy if approved.

#### duckflux (~10 lines of flow)

```yaml
# participants: coder (agent), reviewer (agent), deploy (exec)

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

Participants are defined separately (like Argo's templates). The flow itself is linear, readable, and self-contained.

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

GitHub Actions has no conditional loop construct. The workaround is to unroll iterations manually with `if` guards on each step, or use recursive reusable workflows in separate files. The deploy condition becomes a monstrous OR chain across all possible reviewer outputs (`steps.reviewer1.outputs.approved == 'true' || steps.reviewer2.outputs.approved == 'true' || ...`).

#### n8n (~70 lines JSON)

n8n has no loop primitive. The workaround requires a JavaScript Function node for iteration counting, an IF node for control flow, and circular node connections. The reference syntax `$node['Reviewer'].json.approved` is verbose and fragile — renaming a node breaks all references. The visual editor makes it intuitive, but the exported JSON spec is unreadable.

#### Temporal (~35 lines Go)

```go
for i := 0; i < 3; i++ {
    err := workflow.ExecuteActivity(ctx, CoderActivity, ...).Get(ctx, &coderOutput)
    // ...
    if reviewerOutput.Approved { break }
}
```

Clear for Go developers, but it is code — not a spec. Requires compilation, worker deployment, and a Temporal server. The developer does not "read the flow" — they read programming logic.

#### Airflow (impossible natively)

Airflow DAGs are acyclic by definition. Conditional loops are architecturally impossible without sub-DAGs or the DAG triggering itself recursively, which adds scheduling latency between each iteration.

### 12.2 Comparative Summary

| Feature | duckflux | Argo | GHA | n8n | Temporal | Airflow | Lobster | Ralph |
|---------|---------|------|-----|-----|----------|---------|---------|-------|
| Conditional loop | native | template recursion | unroll | JS hack | code | impossible | no | global event loop |
| Fixed loop | native | native | no | JS hack | code | no | no | max_iterations |
| Parallelism | native | native | jobs | visual | goroutines | native | no | no |
| Conditional branch | native | when | if | IF node | code | BranchOperator | condition | no |
| Guard (when) | native | when | if per step | no | code | no | no | triggers |
| Error handling | onError + retry + fallback | retryStrategy | continue-on-error | no | code | no | no | no |
| Timeout | global + per-step | per-step | per-job | per-node | per-activity | per-task | no | global only |
| Sub-workflows | native | template ref | reusable workflows | sub-workflow node | child workflow | SubDagOperator | no | no |
| Typed expressions | Google CEL | custom template | custom `${{ }}` | `={{ }}` + JS | native code | Python | `$step.stdout` | no |
| Runtime variables | 6 namespaces | parameters | contexts | `$node[]` | typed structs | XCom | stdout only | scratchpad file |
| Input/Output schema | JSON Schema opt-in | parameters | inputs | JSON | typed structs | XCom | JSON stdout | scratchpad .md |
| Spec is readable as text | yes | partially | partially | no (JSON) | no (code) | no (Python) | yes | yes |
| Flow determinism | total | total | total | total | total | total | total | partial |
| Requires infrastructure | no | Kubernetes | GitHub | n8n server | Temporal server + worker | Airflow + scheduler + DB | no | no |

---

## 13. Complete Example

A full workflow demonstrating multiple features together:

```yaml
name: code-review-pipeline
version: 1

defaults:
  timeout: 10m

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
    type: agent
    as: "Code Builder"
    model: claude-sonnet-4-20250514
    tools: [read, write, bash]
    timeout: 15m
    onError: retry
    retry:
      max: 2
      backoff: 5s
    input:
      repo: input.repoUrl
      branch: input.branch

  reviewer:
    type: agent
    as: "Code Reviewer"
    model: claude-sonnet-4-20250514
    tools: [read]
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

  tests:
    type: exec
    run: npm test
    timeout: 5m
    onError: skip

  lint:
    type: exec
    run: npm run lint
    timeout: 2m
    onError: skip

  deploy:
    type: exec
    run: ./deploy.sh
    timeout: 5m
    onError: notify

  notify:
    type: http
    url: https://hooks.slack.com/services/T00/B00/xxx
    method: POST

flow:
  - coder

  - loop:
      until: reviewer.output.approved == true
      max: input.maxReviewRounds
      steps:
        - reviewer
        - coder:
            when: reviewer.output.approved == false

  - parallel:
      - tests
      - lint

  - if:
      condition: tests.status == "success" && lint.status == "success"
      then:
        - deploy
      else:
        - notify

output:
  approved: reviewer.output.approved
  score: reviewer.output.score
  testResult: tests.status
  lintResult: lint.status
```

---

## 14. Tooling

### 14.1 JSON Schema

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

- Top-level structure (`name`, `participants`, `flow`, `inputs`, `output`, `defaults`)
- Participant types and their type-specific fields
- Reserved participant names (`workflow`, `execution`, `input`, `output`, `env`, `loop`)
- Flow constructs (`loop`, `parallel`, `if`, `when` guards, participant overrides)
- Loop requires at least `until` or `max`
- Duration format (`30s`, `5m`, `2h`)
- Retry config structure
- Input schema fields (JSON Schema subset)

**What the schema does NOT validate** (requires a linter or runtime):

- CEL expression syntax and type correctness
- Cross-references (participant in flow exists in `participants`)
- `onError` redirect targets exist
- Sub-workflow file paths resolve
- Circular dependencies

### 14.2 Tooling Roadmap

| Phase | Tool | Purpose |
|-------|------|---------|
| v1 (now) | JSON Schema | Editor validation + autocomplete via YAML extension |
| v1.5 | CLI linter (`duckflux lint`) | Structural validation, cross-reference checks, CEL parse |
| v2 | Language Server (LSP) | Contextual autocomplete, go-to-definition, hover docs, real-time diagnostics |

---

## 15. Roadmap (v2+)

Features deliberately out of scope for v1. Deferred to future versions based on real-world demand:

- **DAG mode** — Explicit step dependencies (`depends: [stepA, stepB]`) instead of linear sequence. Sequence + parallel covers 95% of cases today, but complex graphs with many cross-dependencies become hard to express linearly.

- **Signals + wait** — External input during execution and a `wait:` primitive in the flow that pauses until a signal is received or a condition becomes true. These are interdependent: `wait` without signals has no mechanism to receive external data. The `human` participant type covers the basics for now.

- **Hooks (participant type)** — Participant that emits signals outside the workflow (webhooks, notifications, events). Complementary to signals: hooks emit, signals receive. Combined, they enable bidirectional communication with external systems mid-flow, including external control of execution (e.g., cancellation). The `hook` type is already declared in participants; full implementation depends on signals.

- **Durability / resume** — Workflow survives a runtime crash and resumes from where it stopped. Requires storage and state serialization decisions; this is a runtime feature, not a spec feature. Reference: Lobster has resume tokens as a first-class feature.

- **Matrix / fan-out** — Combinatorial execution (e.g., run tests across 3 Node versions x 2 operating systems). Useful for CI, outside the core use case.

- **Secrets management** — Dedicated credential store with rotation and auditing. `env` is sufficient for now; secret store is an infrastructure decision.

- **Workflow versioning** — Run v1 and v2 simultaneously with gradual migration. Relevant when there are multiple executions in production.

- **Caching between runs** — Reuse outputs from idempotent steps across executions. Performance optimization, not functionality.

- **Backpressure / gates** — Gates that reject incomplete work and force re-execution (e.g., tests did not pass → reject the builder's output). Reference: Ralph Orchestrator uses backpressure as a quality mechanism.

- **Declarative guardrails** — Textual rules that agents must follow during execution (e.g., "YAGNI", "tests are mandatory"). Reference: Ralph defines guardrails as a string array in YAML.

- **Persistent mode** — Workflow running as a daemon, reacting to events continuously instead of single execution. Reference: Ralph supports persistent mode.

- **Concurrency control** — Limit parallel executions of the same workflow or specific steps. Prevents race conditions on shared resources. Reference: GitHub Actions has concurrency groups.

- **YAML anchors / fragments** — Reuse of configuration blocks within the same file via YAML anchors (`&` / `*`). Reference: Ralph supports YAML anchors for sharing instruction blocks across hats.

**Note:** DAG + signals + wait + hooks combined cover the full event-driven model without requiring a separate `events:` keyword. The approach is to extend the existing `flow:` instead of creating a parallel paradigm.

---

## 16. Decisions Log

Decisions made during the design of this spec, with rationale:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Expression language | Google CEL | Runtime-agnostic (Go, Rust, JS), sandboxed, type-checked at parse time, familiar syntax. Rejected: `eval()`/JS (ties to one runtime), custom mini-DSL (every function is a ticket), JSONPath (poor logic support). |
| Variable access | Direct by name (`reviewer.output`) | Better DX than `steps.reviewer.output`. Tradeoff: shared namespace with reserved words, enforced at parse time. |
| Step output on re-execution | Last execution only | Simpler mental model. `reviewer.output` always means "the most recent result". History was considered but deferred — 90% of cases only need the latest value. |
| Input/Output default | String | Like stdin/stdout — the universal interface. Allows any content type. Schema is opt-in via JSON Schema. |
| Schema format | JSON Schema in YAML | Industry standard, validators available in every language. `required: true` shortcut per field is sugar normalized at parse time. |
| Error handling levels | Participant (default) + flow (override) | Follows the same precedence pattern as timeout. Enables both "this step always retries" and "in this specific invocation, skip on error". |
| Workflow output default | Last executed step | Convention over configuration. Explicit mapping is available but not required. |
| Triggers | Deferred to runtime | Trigger types and configuration are infrastructure decisions, not spec decisions. The DSL defines flow, not scheduling. |
| Event-driven model | Deferred (DAG + signals + wait + hooks) | Sequential flow with parallel/when/loop covers the primary use cases. Event-driven is achievable by extending `flow:` rather than introducing a competing paradigm. |

---

*Version 0.1 — March 2026*
