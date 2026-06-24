# TestLens

> Improved test output and tooling for Elixir, Phoenix, and OTP codebases.

TestLens is a thin wrapper around `mix test` that registers an additional
ExUnit formatter and gives you a slightly nicer terminal experience — a
clear banner, a consistent summary, optional JSON output, and a hook for
future impact-analysis features. It does not replace ExUnit.

## Goal

Make `mix test` output easier to scan on large projects without giving up
ExUnit's runner, configuration, or `--failed` / `--stale` / `--seed` flags.
TestLens passes through every argument you give it after `--`, so anything
`mix test` understands still works.

## Non-goals

- Not a new test framework. It does not replace ExUnit.
- It does not parse raw terminal output. It runs as a real ExUnit formatter.
- It does not require Phoenix, Ecto, or OTP. It works on any Elixir project.
- It is not a code coverage tool, a mutation tester, or a flaky-test detector
  (those are future directions).
- It is not a fork. The default ExUnit formatter is preserved alongside
  TestLens so you keep the familiar dot-progression output.

## Installation

> **Status:** v0.1.0 alpha. APIs may change.

`test_lens` will be published to Hex in a future release. For v0.1.0, add it
as a path dependency pointing at this repository:

```elixir
# mix.exs
defp deps do
  [
    {:test_lens, path: "../test_lens", only: :test, runtime: false}
  ]
end
```

Then fetch and compile:

```sh
mix deps.get
```

No configuration is required. The `mix test.lens` task is registered
automatically.

## Usage

Run the full suite with the TestLens formatter:

```sh
mix test.lens
```

Pass any `mix test` flag through after `--`:

```sh
# Rerun only the tests that failed last time
mix test.lens -- --failed

# Rerun tests whose source has changed
mix test.lens -- --stale

# Deterministic order for a flaky investigation
mix test.lens -- --seed 12345

# A single file or line
mix test.lens -- test/foo_test.exs
mix test.lens -- test/foo_test.exs:42
```

Combine TestLens flags with `mix test` flags:

```sh
# JSON output for piping into a dashboard or CI artifact
mix test.lens --json -- --failed
```

### TestLens-specific flags

| Flag         | Effect                                               |
| ------------ | ---------------------------------------------------- |
| `--json`     | Emit a JSON document to stdout AND write the artifact file |
| `--json-file PATH` | Override the artifact file path (default: `_build/test_lens/report.json`) |
| `--html`     | Write the HTML report (default path: `_build/test_lens/report.html`) |
| `--html-file PATH` | Override the HTML report path |
| `--no-color` | Disable ANSI color (the only color we emit is a banner) |
| `--color`    | Force-enable color (default)                          |
| `--impact`   | Reserved for the v0.2.0 changed-files analysis      |
| `--rerun`    | Reserved for the v0.2.0 --failed helper              |
| `-j`         | Alias for `--json`                                    |

Anything before `--` is TestLens; anything after is passed straight to
`mix test`. Run `mix help test.lens` for the in-app help.

## What the output looks like

TTY (default):

```
== TestLens ==
Improved ExUnit output

.....................................
37 passed, 0 failed, 0 skipped, 37 total in 30ms
```

JSON (`--json`):

```json
{"failures":[],"summary":{"excluded":0,"failed":0,"invalid":0,"passed":37,"skipped":0,"times_us":{"async":29711,"run":29711,"load":null},"total":37},"test_lens_version":"0.1.0"}
```

The `ExUnit.CLIFormatter` continues to run alongside TestLens, so you keep
the familiar dot-progression, the "Running ExUnit" line, and the trailing
"37 tests, 0 failures" line.

## Project config (`.test_lens.exs`)

> **Project config supplies meaning. TestLens supplies structure.**

TestLens v0.1.0 introduces `TestLens.ProjectConfig`, a loader for a
project-level `.test_lens.exs` file that lives in your application's root
directory. This file is where **you** define the MEANING of your codebase —
which test paths belong to which areas, which ExUnit tags are critical, and
what impact levels mean in your project. TestLens provides the STRUCTURE:
the schema definitions, the loader, the validator, and the classification
pipeline. The distinction is intentional: TestLens makes no assumptions
about your directory layout, tag vocabulary, or impact vocabulary; those
are for your project to define.

### Schema

A `.test_lens.exs` file is a plain Elixir keyword list:

```elixir
[
  project: "ExampleApp",                    # optional, informational only
  areas: [                                 # optional, default: []
    "test/example_app/accounts" => [        # path prefix
      label: "Accounts",                   # required
      impact: :high,                       # :high | :medium | :low | :none, default: :none
      user_facing: true                    # boolean, default: false
    ],
    "test/example_app_web/live" => [
      label: "LiveView/UI",
      impact: :high,
      user_facing: true
    ],
    "test/example_app/workers" => [
      label: "Background jobs",
      impact: :medium,
      user_facing: false
    ]
  ],
  critical_tags: [:payment, :security, :data_integrity]  # optional, default: []
]
```

**Fields:**

| Field | Type | Default | Purpose |
|---|---|---|---|
| `project` | `String.t()` | `nil` | Informational only; TestLens does not use it |
| `areas` | `[{path, opts}]` | `[]` | Maps path prefixes to area descriptors |
| `critical_tags` | `[atom()]` | `[]` | Tests with any of these tags are marked `critical: true` |

**Area descriptors** (`opts` in the areas list):

| Key | Type | Default | Purpose |
|---|---|---|---|
| `label` | `String.t()` | `"Unnamed"` | Human-readable area name |
| `impact` | `:high \| :medium \| :low \| :none` | `:none` | Impact level for this area |
| `user_facing` | `boolean()` | `false` | Whether this area represents user-facing code |

### Loading semantics

- **Missing file** → empty config (no error, no crash)
- **Invalid Elixir syntax** → empty config + warning on stderr
- **File evaluates to non-list** → empty config + warning on stderr
- **File raises on evaluation** → empty config + warning on stderr

`TestLens.ProjectConfig.load/1` returns `{:ok, config}` or `{:error, reason}`.
`TestLens.ProjectConfig.load_or_default/1` (used internally by `Impact.classify/3`)
returns the config or an empty struct and logs a warning on failure.

### `classify/3` result

When you call `TestLens.Impact.classify/3` (or leave the config argument as
`nil` to auto-load), you get a `%TestLens.Impact{}` struct:

```elixir
%TestLens.Impact{
  area: "Accounts" | nil,          # label from the matched area, or nil
  impact: :high,                   # :high | :medium | :low | :none
  user_facing: true,               # boolean
  critical: true,                  # true if critical tag matched OR (impact == :high AND user_facing)
  reason: "matches area \"Accounts\"" | "tagged critical: payment, security" | "no matching area or tag"
}
```

### Priority rules

1. **Critical tag wins over area** — if any of the test's tags is in
   `critical_tags`, the result is `critical: true`, `impact: :high`,
   and a `"tagged critical: ..."` reason. The area's data is not used.
2. **Path match** — if the test's file path starts with an area prefix,
   the matched area's data is used. `critical` is `true` only when
   `impact == :high AND user_facing == true`.
3. **Default** — no tag match, no path match: all fields are `:none` / `false` / `nil`.

### Safety guarantees

`load/1` and `load_or_default/1` **never raise**. Missing file, invalid
syntax, invalid shape — all result in a safe empty config (with a warning
logged to stderr for `load_or_default/1`).

### Extending

Because the config file is just Elixir, you can read it from your own code:

```elixir
{:ok, config} = TestLens.ProjectConfig.load()
# Use config.areas and config.critical_tags in your own impact analysis
```

For v0.2.0, the `--impact` flag will use `TestLens.Impact.changed_files_since/1`
and `TestLens.Impact.affected_tests/2` to run only tests likely affected by
changed files.

## JSON artifact for agents and CI

When you run `mix test.lens --json` (or `mix test.lens --json-file PATH`), TestLens
writes a structured JSON document to a file. The document is the same data the
human-facing TTY report shows, but in a form that is easy for AI agents, CI
scripts, and other tools to consume without having to scrape or parse terminal
output.

**Default location:** `_build/test_lens/report.json` (relative to the project root).

**Example invocation:**

```sh
mix test.lens --json-file tmp/test_lens/report.json -- --failed
```

**Small JSON example:**

```json
{
  "test_lens_version": "0.1.0",
  "project": "ExampleApp",
  "timestamp": "2026-06-24T10:00:00.000000Z",
  "seed": 12345,
  "totals": {
    "tests": 50,
    "passed": 45,
    "failed": 2,
    "skipped": 3,
    "excluded": 0,
    "invalid": 0
  },
  "times_us": { "run": 1234, "async": 567, "load": null },
  "failures": [ ... ],
  "slow": [ ... ],
  "classification_counts": { "function_clause": 1, "assertion": 1 },
  "next_commands": [ ... ]
}
```

### How an AI agent uses the artifact

After a failed run, the agent can read `_build/test_lens/report.json`
instead of scraping terminal output:

```sh
# Find every failure
jq '.failures[] | {module, name, classification, impact}' \
   _build/test_lens/report.json

# Get the suggested next command
jq -r '.next_commands[] | .command' _build/test_lens/report.json

# Count failures by type
jq '.classification_counts' _build/test_lens/report.json
```

The schema is stable: a failure entry always has `module`, `name`,
`file`, `classification` (with `type`, `plain_english`,
`suggested_checks`), and `impact` (with `area`, `critical`,
`reason`). An agent can plan a fix from those fields without
re-running the suite.

### What is NOT included

- No environment variables, no `System.get_env/1`, no shell dumps.
- No `Mix.Project.config/0` (which can contain DB credentials, API
  keys, etc. for the consumer's project).
- No ExUnit logs (logs may contain sensitive data).
- No raw application config.

## HTML report

For PR/issue/agent-review attachments. Self-contained, no external assets, no JavaScript.

**Default location:** `_build/test_lens/report.html` (relative to the project root).

**Example invocations:**

```sh
mix test.lens --html                    # writes to _build/test_lens/report.html
mix test.lens --html-file PATH          # writes to PATH
```

**Sections (in order):**

1. **Summary** — total counts and run time
2. **Critical failures** — failures with `default_severity: :critical` (exit/throw)
3. **Failures by area** — grouped by `impact.area`
4. **Failures by type** — grouped by `classification.type` (same as JSON `classification_counts`)
5. **Slow tests** — top 5 by duration
6. **Suggested reruns** — the same next commands as the JSON artifact
7. **Raw failure details** — `<details>` per failure with classification, impact, and raw body

The HTML report contains the same normalised data as the JSON artifact — same counts, same classifications, same groupings — in a form that humans (and AI agents reviewing PRs) can scan without installing `jq` or parsing JSON.

## Architecture (one paragraph)

`mix test.lens` is a thin `Mix.Task` (`Mix.Tasks.Test.Lens`) that parses
its own flags, builds a `TestLens.Config`, and delegates to `Mix.Tasks.Test`
with `--formatter TestLens.Formatter` added. `TestLens.Formatter` is a plain
`use GenServer` module (ExUnit formatters have no behaviour in Elixir
1.18/1.19). It listens to `handle_cast/2` events, converts each
`%ExUnit.Test{}` into a `TestLens.Result`, stores it in a `TestLens.EventStore`
Agent, and at `suite_finished` it renders the output via
`TestLens.TerminalReporter`. Test classification runs through
`TestLens.Classifier`, which consults a small registry of adapters under
`lib/test_lens/adapters/` — Phoenix, LiveView, Ecto, and OTP for v0.1.0.
The `--json` flag switches the reporter to a hand-rolled JSON encoder (no
external dep).

## License

MIT. See [LICENSE](./LICENSE).
