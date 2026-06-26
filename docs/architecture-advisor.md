# TestLens Architecture Advisor (4.0+)

The **architecture advisor** is a separate artifact (`advice.json`) that
captures static AST + supervisor topology findings from your Elixir/OTP
codebase. It runs whenever `mix test.lens --advise` is passed — even
when no tests fail.

## Enabling

```sh
mix test.lens --advise                       # writes _build/test_lens/advice.json
mix test.lens --advise-file PATH             # override the path
mix test.lens --advise -- --failed           # rerun failures, still write advice.json
mix test.lens --advise --snapshot            # combine with --snapshot for runtime context
```

When `--advise` is enabled, the advisor runs on `:suite_finished` and
the formatter appends a single footer line:

```
Advice artifact: _build/test_lens/advice.json
```

## Schema (`schema_version: "4.0"`)

| Key | Type | Purpose |
|---|---|---|
| `schema_version` | `"4.0"` | Stable contract for consumers. |
| `test_lens_version` | string | TestLens release that wrote the artifact. |
| `project` | string \| null | From `.test_lens.exs` `:project`. |
| `run` | map | `command`, `cwd`, `elixir` version. |
| `totals` | map | `total`, `error`, `warn`, `info` counts. |
| `findings[]` | list | One finding per rule firing. |
| `safety` | map | Excluded fields and privacy notes. |

Each finding object has:

| Key | Type | Purpose |
|---|---|---|
| `id` | string (12 hex) | Stable per-finding id. |
| `rule_id` | string | One of `cross_tree_call`, `unbounded_mailbox`, `mismatched_restart_strategy`, `raw_process_spawn`, `registry_naming`, `supervisor_no_children`, `rule_error`. |
| `severity` | `error` \| `warn` \| `info` | Action priority. |
| `confidence` | float `0.0..1.0` | Heuristic; never claim certainty. |
| `location` | `%{file, line}` | Best-effort source pointer. |
| `evidence` | string | What matched. |
| `explanation` | string | One-sentence hedged description. |
| `remediation` | string | One-sentence suggested next step. |
| `related_modules[]` | string[] | `Elixir.<App>.<Role>` strings. |

## Rule catalog

| Rule ID | Severity | Confidence | What it catches |
|---|---|---|---|
| `cross_tree_call` | warn | 0.85 | `GenServer.call` whose caller and callee are in different supervision subtrees. |
| `unbounded_mailbox` | info | 0.70 | Cross-tree call without `timeout:` in source. |
| `mismatched_restart_strategy` | info | 0.50 | Reserved for v4.1. Stub in 4.0; never fires. |
| `raw_process_spawn` | warn | 0.90 | Direct `:erlang.spawn/1+`, `:erlang.spawn_link/1+`, `:erlang.spawn_monitor/1+`, `Task.start/1`. |
| `registry_naming` | info | 0.60 | `Process.register/2` with a name that doesn't start with `Elixir.`. |
| `supervisor_no_children` | info | 0.50 | A registered supervisor with no children at topology capture time. |
| `rule_error` | info | 1.00 | The rule itself raised. Other rules still apply. |

Each finding's `confidence` is a rough heuristic. Treat `confidence < 0.7`
as "needs human review".

## How it integrates with the agent artifact

When `--advise` is combined with `--agent`, the architecture findings
are also embedded in the agent artifact under `architecture_findings[]`
(v4.0+). The same `id` is used in both artifacts so consumers can join:

```json
{
  "agent.json#architecture_findings": [
    {"id": "a7fd11102f26", "rule_id": "cross_tree_call", "severity": "warn", "confidence": 0.85, "evidence": "..."}
  ],
  "advice.json#findings": [
    {"id": "a7fd11102f26", "rule_id": "cross_tree_call", "severity": "warn", "confidence": 0.85, "evidence": "..."}
  ]
}
```

## Limits

- Static AST analysis is conservative: metaprogrammed modules,
  compile-time `Code.eval_quoted`, and dynamic dispatch are not modeled.
- `:supervisor.child_spec/1` introspection is not yet exposed in
  Elixir 1.19, so `mismatched_restart_strategy` is a stub in 4.0.
- The `supervisor_no_children` rule uses `Application.started_applications/0`
  + `Process.whereis/1`; it reflects the dev-time VM, not production.

## Why a separate artifact (not TTY/HTML)?

The advisor is **machine-first**. Findings carry enough structured
context that an AI agent can prioritize and act on them. Mixing them
into the TTY or HTML reports would dilute the human-focused design.

## Worked example

```json
{
  "schema_version": "4.0",
  "totals": {"total": 1, "warn": 1, "info": 0, "error": 0},
  "findings": [
    {
      "id": "a7fd11102f26",
      "rule_id": "cross_tree_call",
      "severity": "warn",
      "confidence": 0.85,
      "location": {"file": null, "line": null},
      "evidence": "GenServer.call from MyApp.Billing to MyApp.Payments",
      "explanation": "These modules likely live in different supervision subtrees...",
      "remediation": "Move the call under a shared parent, use async cast, or...",
      "related_modules": ["Elixir.MyApp.Billing", "Elixir.MyApp.Payments"]
    }
  ]
}
```
