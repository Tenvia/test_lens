# TestLens Agent Artifact (2.0+)

The **agent artifact** is a machine-first JSON document that AI coding
agents consume to triage failing Elixir tests. It is generated alongside
the human-facing TTY and HTML reports and is intentionally separate from
them: the human reports stay clean, the agent artifact carries dense,
structured context that agents can act on.

## Enabling

```sh
mix test.lens --agent                      # write _build/test_lens/agent.json
mix test.lens --agent-file PATH            # override the path
mix test.lens --agent -- --failed          # rerun failures, still write the artifact
```

When the artifact is written, a single footer line is appended to the
TTY output:

```
Agent artifact: _build/test_lens/agent.json
```

## Schema (`schema_version: "2.0"`)

Top-level shape:

| Key | Type | Purpose |
| --- | --- | --- |
| `schema_version` | `"2.0"` | Stable contract for consumers. |
| `test_lens_version` | string | TestLens release that wrote this artifact. |
| `project` | string \| null | From `.test_lens.exs` `:project`. |
| `run` | map | `command`, `cwd`, `elixir`, `seed`. |
| `totals` | map | `tests`, `passed`, `failed`, `skipped`, `invalid`, `excluded`. |
| `failures` | list | One entry per failed test (see below). |
| `repair_queue` | list | Failures grouped by fingerprint and ranked by priority. |
| `commands` | list | Suggested next commands (`--failed`, `--stale`, `--seed N`). |
| `safety` | map | Excluded fields and human-readable privacy notes. |

## Failure entry

| Key | Type | Purpose |
| --- | --- | --- |
| `id` | string (12 hex) | Stable identifier across runs. |
| `module`, `name`, `file` | string | Test identity. |
| `line` | int \| null | Prefer `Result.line/1` (`@tag line: N`), then top app frame. |
| `time_us` | int | Test duration in microseconds. |
| `failure_kind` | string | One of `error`, `exit`, `exit_timeout`, `throw`, `invalid`. |
| `severity` | `critical` \| `other` | From the classifier's `default_severity`. |
| `classification` | map | Classifier output: `type`, `plain_english`, `common_causes`, `suggested_checks`, `likely_layer`. |
| `impact` | map | `TestLens.Impact` fields: `area`, `impact`, `user_facing`, `critical`, `reason`. |
| `fingerprint` | string (64 hex) | Stable SHA-256 over `(kind, classification.type, file, top_app_frame)`. |
| `top_app_frame` | map \| null | Best frame to look at first. |
| `app_stacktrace` | list | Stacktrace frames inside the consumer's project. |
| `framework_stacktrace` | list | Stacktrace frames under Elixir/OTP stdlib. |
| `deps_stacktrace` | list | Stacktrace frames under consumer deps. |
| `hypotheses` | list | Hedged hypotheses sourced from the classifier. |
| `rerun_command` | string | Exact command to reproduce this test. |

## Repair queue entry

| Key | Type | Purpose |
| --- | --- | --- |
| `id` | string | Stable per-fingerprint identifier. |
| `priority` | `critical` \| `user_facing` \| `high` \| `normal` | Sort key. |
| `confidence` | float (0.0–0.95) | Coarse heuristic: known classification + top app frame → high. |
| `failure_ids` | list | Failures in this group. |
| `root_cause_fingerprint` | string | Same fingerprint the failures share. |
| `summary` | string | Human-readable one-liner. |
| `evidence` | list | Top app frames in the group. |
| `likely_files` | list | Files an agent should open first. |
| `first_checks` | list | Suggested checks from the classifier. |
| `verification_commands` | list | Exact rerun commands. |

## Stability

The `schema_version` is the contract. Within a given `schema_version`,
new fields may appear; existing fields do not change shape. Consumers
should:

1. Branch on `schema_version`.
2. Ignore unknown fields.
3. Treat nested classifications as opaque strings unless they need to
   match specific types.

## What is NOT included

The agent artifact follows the same privacy discipline as the JSON
artifact:

- No environment variables (`System.get_env/1`).
- No `Mix.Project.config/0`.
- No raw ExUnit logs.
- No raw message payloads.
- No application config.

The `safety` block declares this list explicitly so consumers can
verify the discipline holds.

## Worked example

```json
{
  "schema_version": "2.0",
  "test_lens_version": "2.0.0",
  "totals": {"tests": 1, "passed": 0, "failed": 1},
  "failures": [
    {
      "id": "ff8e027fa45c",
      "module": "MyApp.FooTest",
      "name": "test boom",
      "file": "test/my_app/foo_test.exs",
      "failure_kind": "error",
      "severity": "other",
      "fingerprint": "a7fd11102f26589d8b6065db05290b83cd6a8edb79da7ff446ec718008027522",
      "top_app_frame": {
        "module": "Elixir.MyApp.Foo",
        "function": "bar",
        "arity": 1,
        "file": "lib/my_app/foo.ex",
        "line": 42
      },
      "app_stacktrace": [
        {"module": "Elixir.MyApp.Foo", "function": "bar", "arity": 1, "file": "lib/my_app/foo.ex", "line": 42}
      ],
      "deps_stacktrace": [
        {"module": "Elixir.Example", "function": "render", "arity": 2, "file": "deps/example/lib/example.ex", "line": 5}
      ],
      "rerun_command": "mix test.lens -- test/my_app/foo_test.exs:42"
    }
  ],
  "repair_queue": [
    {
      "id": "repair_a7fd1110",
      "priority": "normal",
      "confidence": 0.5,
      "failure_ids": ["ff8e027fa45c"],
      "summary": "MyApp.FooTest > test boom (unknown)",
      "likely_files": ["test/my_app/foo_test.exs", "lib/my_app/foo.ex"],
      "first_checks": ["inspect the error and stacktrace"],
      "verification_commands": ["mix test.lens -- test/my_app/foo_test.exs:42"]
    }
  ]
}
```
