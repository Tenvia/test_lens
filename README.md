# TestLens

> Better ExUnit output and tooling for Elixir, Phoenix, and OTP codebases.
> Drop-in formatter, stable JSON artifact, self-contained HTML report,
> and a separate agent repair artifact for AI coding assistants.

## What TestLens is

TestLens is a **formatter + reporter** for ExUnit. It wraps `mix test` with a
second formatter that normalises per-test events, enriches them with failure
classifications and impact assessments, and renders a human-readable summary
to the terminal. It also emits a **stable JSON artifact**, a **self-contained
HTML report**, and (since 2.0) a separate **agent repair artifact** for AI
coding agents.

TestLens is not a new test framework. It does not replace ExUnit, nor does
it run the tests differently. It sits alongside the existing `ExUnit.CLIFormatter`
so you keep the familiar dot-progression and the trailing summary line.

## What TestLens is not

- **Not a new test framework** — ExUnit runs your tests as normal.
- **Not a replacement for ExUnit** — TestLens is a formatter, not a runner.
- **Not a code coverage tool** — use `mix test --cover` for that.
- **Not a mutation tester** — use [Mutation](https://github.com/mustelideos/mutation) or [Matrex](https://github.com/mimest/Matrex) for that.
- **Not a Phoenix feature testing library** — no browser automation, no wallaby-style
  session management, no LiveViewTest replacement.
- **Not a JUnit XML formatter** — use [junit_formatter](https://hex.pm/packages/junit_formatter) for that.
- **Not a watch tool** — use [mix_test_watch](https://hex.pm/packages/mix_test_watch) for that.
- **Not a test runner that forks ExUnit** — TestLens does not spawn separate
  processes or VMs.

## How TestLens differs from

### Watch tools (`mix test --watch`, `file_system`, `mix_test_watch`)
TestLens only runs the tests — it does not watch the filesystem for changes.
Pair them: run `mix test.lens -- --stale` from a watch task to get TestLens
output on every save.

### JUnit XML formatters (`junit_formatter`, `mix junit`)
JUnit XML is for CI dashboards (CircleCI, GitHub Actions test reporting).
TestLens is for the developer's terminal and the agent reviewing a PR. They are
complementary; use both — `mix test.lens --json` for the artifact, and configure
your CI to also emit JUnit XML.

### Phoenix feature testing libraries (`wallaby`, `waller`, `phoenix_test`)
TestLens does not drive a browser or simulate a user session. It improves the
output of the tests you already have. If you use wallaby, TestLens will
classify wallaby session errors the same way it classifies any other ExUnit failure.

## Installation

> **Status:** `2.0.0` — stable. JSON schema is `1.0`, agent artifact schema is `2.0`.

Add to your project's `mix.exs`:

```elixir
defp deps do
  [
    {:test_lens, "~> 2.0"}
  ]
end
```

Then fetch and compile:

```sh
mix deps.get
```

No configuration is required. The `mix test.lens` task is registered automatically.

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

# HTML report attached to a PR
mix test.lens --html -- --failed
```

## Project config (`.test_lens.exs`)

> **Why this matters:** Without `.test_lens.exs`, every test is
> `area: nil, impact: :none`. The config is what makes TestLens output
> actionable — you decide which paths are user-facing, which tags are
> critical. TestLens supplies the structure; the project supplies the meaning.

TestLens loads a `.test_lens.exs` file from your project root. This file is
where **you** define which test paths belong to which areas of the codebase,
which ExUnit tags are critical, and what impact levels mean. TestLens
provides the structure: the schema definitions, the loader, the validator,
and the classification pipeline.

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
`TestLens.ProjectConfig.load_or_default/1` returns the config or an empty
struct and logs a warning on failure.

### `classify/3` result

When you call `TestLens.Impact.classify/3` (or leave the config argument as
`nil` to auto-load), you get a `%TestLens.Impact{}` struct:

```elixir
%TestLens.Impact{
  area: "Accounts" | nil,          # label from the matched area, or nil
  impact: :high,                   # :high | :medium | :low | :none
  user_facing: true,               # boolean
  critical: true,                  # true if critical tag matched OR (impact == :high AND user_facing)
  reason: "matches area \"Accounts\"" | "tagged critical: ..." | "no matching area or tag"
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

## Reports (JSON, HTML)

TestLens emits two structured report formats. Both contain the same normalised
data: counts, classifications, impact assessments, slow tests, and suggested reruns.
They differ only in format — choose based on who or what is consuming the output.

### Stable schema (`schema_version`)

Every JSON artifact carries a top-level `"schema_version": "1.0"` field.
TestLens `1.x` keeps the schema additive: new fields may appear, existing
fields do not change shape. Consumers should branch on `schema_version` and
ignore unknown fields. The full schema is documented in
`TestLens.JSONReport`'s moduledoc.

### JSON artifact

**Default path:** `_build/test_lens/report.json`

```sh
mix test.lens --json                    # write artifact + print to stdout
mix test.lens --json-file PATH          # write artifact to PATH
mix test.lens --json -- --failed       # rerun failures, write artifact
```

The JSON schema is stable within `schema_version "1.0"`.

Example failure entry shape:

```json
{
  "module": "MyApp.UserAuthTest",
  "name": "test login with valid credentials",
  "file": "test/user_auth_test.exs",
  "classification": {
    "type": "function_clause",
    "plain_english": "A function likely received data in a shape it does not handle.",
    "suggested_checks": ["..."]
  },
  "impact": {
    "area": "Accounts",
    "critical": true,
    "reason": "matches area \"Accounts\""
  }
}
```

### HTML report

**Default path:** `_build/test_lens/report.html`

For PR/issue/agent-review attachments. Self-contained: no external CSS, no
JavaScript, no web fonts.

```sh
mix test.lens --html                    # write to _build/test_lens/report.html
mix test.lens --html-file PATH          # write to PATH
```

**Sections (in order):** Summary, Critical failures, Failures by area,
Failures by type, Slow tests, Suggested reruns, Raw failure details.

### CI integration

In CI, run `mix test.lens --json`. The artifact is at
`_build/test_lens/report.json` (or `--json-file PATH`). Upload it as a build
artifact:

```yaml
# GitHub Actions
- uses: actions/upload-artifact@v4
  with:
    name: test-lens-report
    path: _build/test_lens/report.json

# CircleCI
- store_artifacts:
    path: _build/test_lens/report.json
```

For humans reviewing a PR, run `mix test.lens --html` and attach
`_build/test_lens/report.html` to the PR.

### What is NOT included

No environment variables. No `Mix.Project.config/0` (which can contain DB
credentials, API keys, etc.). No ExUnit logs. No raw application config.

## Disable color

```sh
mix test.lens --no-color
```

The JSON and HTML outputs are uncolored by design — they are data formats,
not display formats.

## Configuration reference

| Flag | Effect |
| --- | --- |
| `--json` | Emit JSON to stdout AND write the JSON artifact file |
| `--json-file PATH` | Override the JSON artifact path (default: `_build/test_lens/report.json`) |
| `--html` | Write the HTML report (default: `_build/test_lens/report.html`) |
| `--html-file PATH` | Override the HTML report path |
| `--agent` | Write the agent repair artifact (default: `_build/test_lens/agent.json`) |
| `--agent-file PATH` | Override the agent artifact path |
| `--snapshot` | Capture OTP runtime snapshots at failure time into the agent artifact |
| `--snapshot-dir PATH` | Also write per-failure snapshot NDJSON files to PATH |
| `--no-color` | Disable ANSI color (the only color we emit is the banner) |
| `--color` | Force-enable color (default) |
| `-j` | Alias for `--json` |

Anything before `--` is TestLens; anything after is passed straight to `mix test`.

## Agent repair artifact

The agent artifact is a separate, machine-first JSON document that AI coding
agents consume to triage failing Elixir tests. It carries stable failure
identities and grouping fingerprints, app/framework/deps stacktrace splits,
the top application frame, ranked repair targets with first-checks, hedged
root-cause hypotheses, and exact verification commands.

It is opt-in (`--agent`) and is intentionally separate from the TTY and HTML
reports. Human-facing surfaces stay clean; the agent artifact lives at
`_build/test_lens/agent.json`. See `docs/agent-artifact.md` for the full
schema and worked example.

## OTP runtime snapshots

When `--snapshot` is enabled, TestLens captures test-time OTP runtime
context at the moment a test fails: supervision subtree, process info (with
a safety denylist applied), GenServer state hashes, and a bounded ring buffer
of `:telemetry` events. Snapshots live in the agent artifact under the top
level `otp_snapshots[]` array, with a small pointer on each affected
failure's `otp_context` field.

`--snapshot-dir PATH` also writes one NDJSON file per failed test to PATH,
useful for streaming consumers that want one file per failure.

The TTY and HTML reports are unchanged. See `docs/otp-snapshots.md` for the
full schema, safety guarantees, and worked example.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Bug reports, feature requests,
and pull requests are welcome. Please file issues before opening large PRs.

## Architecture (one paragraph)

`mix test.lens` is a thin `Mix.Task` (`Mix.Tasks.Test.Lens`) that parses
its own flags, builds a `TestLens.Config`, and delegates to `Mix.Tasks.Test`
with `--formatter TestLens.Formatter` added. `TestLens.Formatter` is a plain
`use GenServer` module (ExUnit formatters have no behaviour in Elixir
1.18/1.19). It listens to `handle_cast/2` events, converts each
`%ExUnit.Test{}` into a `TestLens.Result`, stores it in a `TestLens.EventStore`
Agent, and at `suite_finished` it renders the output via
`TestLens.TerminalReporter`. Failure classification runs through
`TestLens.Classifier`, which consults a small registry of failure adapters
under `lib/test_lens/failure_adapters/`. The `--json` and `--html` flags
write canonical artifacts via `TestLens.JSONReport` and `TestLens.HTMLReport`,
both pure builders with no external dependencies.

## License

MIT. See [LICENSE](./LICENSE).
