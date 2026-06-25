# Changelog

All notable changes to TestLens will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - 2026-06-25

### Added

- **OTP runtime snapshots** — opt-in (`mix test.lens --snapshot`) capture of
  test-time runtime context (supervision subtree, process info,
  GenServer state hashes, telemetry events) at the moment a test fails.
  Snapshots are written into the agent artifact; TTY and HTML reports
  stay clean.
- New module `TestLens.OTPSnapshot` with safe-pid guard, registered-name
  denylist (`token`, `secret`, `password`, `key`, `credential`, `auth`),
  bounded supervision subtree walk (depth ≤ 6, breadth ≤ 64, capture
  timeout ≤ 100 ms).
- New module `TestLens.TelemetryBridge` — attaches to the consumer's
  `:telemetry` stream (supervisor, gen_server, oban, broadway prefixes)
  with a bounded ring buffer (default 64 events).
- Optional runtime dependency on `:telemetry ~> 1.0` (declared
  `optional: true` so it is not pulled in unless the consumer already
  uses it). The bridge detects its absence and silently no-ops.
- New CLI flags `--snapshot` and `--snapshot-dir PATH`. The directory
  flag writes per-failure NDJSON files for streaming consumers.
- `agent artifact schema_version: "3.0"` adds:
  - top-level `"otp_snapshots"` array (empty when `--snapshot` was not used).
  - per-failure `"otp_context": %{"snapshot_id" => ...}` pointer.
  - `"safety"` block extended with `otp_snapshot_safety_reasons` and
    `otp_snapshot_excluded_pids`.
- New docs page `docs/otp-snapshots.md` with full schema, safety
  guarantees, worked example, and known limitations.
- `TestLens.Result.line/1` now also reads the `:line` test tag (ExUnit
  does not yet expose line numbers, but consumers can opt in via
  `@tag line: 42`).
- `TestLens.AgentReport.failure_id/1` is now public so the formatter
  can key OTP snapshots by the same id used in the agent artifact.

### Changed

- `TestLens.version` bumped to `2.0.0` (will be tagged `v3.0.0` at release).
- `TestLens.AgentReport.schema_version` bumped to `"3.0"`.
- `TestLens.AgentReport.build/3` accepts an optional fourth argument
  (`otp_snapshots`); `build/3` (no snapshots) is preserved for backward
  compatibility.
- `TestLens.AgentReport.write/4` accepts an optional fifth argument;
  `write/4` (no snapshots) is preserved.
- `TestLens.Formatter` now starts a `TelemetryBridge` on `:suite_started`
  when `--snapshot` is enabled, captures OTP snapshots for failed
  tests on `:test_finished`, drains the bridge buffer into each
  snapshot, and detaches the bridge on `:suite_finished`.
- `TestLens.Config` adds `snapshot: false` and `snapshot_dir: nil`
  fields with defaults.

### Notes

- The `:telemetry` dep is `optional: true`. Consumers who don't already
  use `:telemetry` will not have it pulled in by TestLens. The bridge
  detects its absence and the snapshot feature degrades to "no telemetry
  events captured" without raising.
- OTP snapshots are taken from the formatter process (not the failing
  test process). ExUnit does not yet expose the test process pid in
  its public API; v3.1 will switch to the test process when ExUnit
  supports it.

## [2.0.0] - 2026-06-25

### Added

- **Agent repair artifact** — a separate, machine-first JSON document
  optimized for AI coding agents that need to triage failing Elixir tests.
  Opt in with `mix test.lens --agent` (writes
  `_build/test_lens/agent.json`) or `--agent-file PATH`. See
  `docs/agent-artifact.md` for the full schema.
- `schema_version: "2.0"` field at the top of the agent artifact.
- `TestLens.AgentReport` module — pure builder + writer, same encoding
  pipeline as `TestLens.JSONReport`.
- `TestLens.Fingerprint` — deterministic SHA-256 fingerprints over
  `(kind, classification.type, file, top_app_frame)` so agents can group
  duplicate root causes across runs.
- `TestLens.Stacktrace` — splits raw failure stacktraces into
  `app_stacktrace`, `framework_stacktrace`, and `deps_stacktrace` so
  agents don't wade through framework noise.
- `TestLens.Result.line/1` — derives a test line number from the
  `:line` tag (ExUnit does not expose lines today; consumers may opt in
  with `@tag line: N`).
- Per-failure `id`, `fingerprint`, `top_app_frame`, `hypotheses`,
  `rerun_command`, and split stacktraces in the agent artifact.
- `repair_queue` — failures grouped by fingerprint and ranked by
  priority (critical → user_facing → high → normal) with `confidence`,
  `summary`, `evidence`, `likely_files`, `first_checks`, and
  `verification_commands`.
- `safety` block in the agent artifact declaring excluded fields
  (env, mix_project_config, application_config, exunit_logs,
  raw_message_payloads).
- Single-line TTY footer (`Agent artifact: <path>`) when the agent
  artifact is written. The TTY and HTML reports are unchanged otherwise.
- `docs/agent-artifact.md` — full schema documentation with worked
  example.

### Changed

- `TestLens.version` bumped to `2.0.0`.
- `TestLens.Config` gains `agent` and `agent_file` fields (defaults:
  `false`, `nil`). `--agent` and `--agent-file PATH` switches added to
  `mix test.lens`.

## [1.0.0] - 2026-06-25

### Added

- Top-level `"schema_version": "1.0"` field on every JSON artifact
  (`TestLens.JSONReport.build/3` and `TestLens.TerminalReporter.render_json/4`).
  Consumers can now branch on a stable, machine-readable contract instead
  of guessing the shape.
- `TestLens.JSONReport.schema_version/0` returns the canonical version string.

### Changed

- `TestLens.TerminalReporter.render_json/4` now delegates to
  `TestLens.JSONReport.build/3` + `JSONReport.encode/1`. The two JSON
  encoders (TTY stdout mirror and on-disk artifact) are now driven from a
  single source of truth, eliminating the previous drift between the
  `summary`/`failures`/`slow` shape and the canonical `totals`/`failures`
  shape.
- `failures[].impact` is consistently an object (the `TestLens.Impact`
  struct as a map) across both encoders. Earlier alpha drafts had this as
  a string in some paths; the 1.0 contract is object-only.
- `mix test.lens` and `TestLens.Config` no longer accept `--impact` or
  `--rerun`. Those flags were parsed in `0.x` but had no behavior; they
  return in `2.0` as part of the agent repair artifact surface.
- `README.md` rewritten for the 1.0 release: Hex install (`~> 1.0`),
  stable-schema section, "Roadmap" pointing at v2 agent artifact, no
  alpha / path-dependency language.
- `TestLens.JSONReport` and `TestLens.HTMLReport` moduledocs reference the
  1.0 contract and `schema_version`.

## [0.1.0] - 2026-06-24

### Added

- `mix format` configuration (`.formatter.exs`); CI runs `mix format --check-formatted`.
- `mix credo` configuration (`.credo.exs`); CI runs `mix credo --strict`.
- GitHub Actions CI workflow (`.github/workflows/ci.yml`) testing Elixir 1.18/1.19 × OTP 27/28.
- `CONTRIBUTING.md` — how to file bugs, request features, and add new classifier/adapter modules.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1).
- `.github/ISSUE_TEMPLATE/` — bug report, classification request, adapter request, report output feedback.
- `fixtures/` — sample TTY, JSON, and HTML outputs as living examples of the report shapes.
- `.tool-versions` — pins Elixir 1.19.5 and OTP 28.0 for asdf.
- `--json` now writes a structured JSON artifact file (default `_build/test_lens/report.json`).
- `--json-file PATH` overrides the artifact path.
- `TestLens.JSONReport` is the new module that builds the artifact. Schema is documented in its moduledoc.
- `--html` and `--html-file PATH` write a self-contained HTML report (no external assets, no JavaScript) for PR/issue/agent-review attachments.
- `TestLens.HTMLReport` is the new module that builds the HTML report.
- `TestLens.Classifier.classify_failure/1` returns a deterministic classification map (`type`, `likely_layer`, `plain_english`, `common_causes`, `suggested_checks`, `default_severity`) for an ExUnit failure tuple `{kind, reason, stacktrace}`.
- 13 new failure adapter modules under `lib/test_lens/failure_adapters/` covering the common Elixir/Phoenix/OTP/Ecto failure shapes.
- `TestLens.Classifier.register_failure_adapter/1` lets consumers prepend a user adapter to the priority list.
- `mix test.lens` task that delegates to `mix test` while injecting the `TestLens.Formatter`.
- `TestLens.Formatter` — a thin ExUnit formatter (`use GenServer`) that normalises events into `TestLens.Result` records.
- `TestLens.Config` — runtime configuration loaded from TestLens CLI flags.
- `TestLens.Result` — normalised per-test result record.
- `TestLens.EventStore` — Agent-based store.
- `TestLens.Classifier` — categorises tests into `:unit`, `:integration`, `:phoenix`, `:live_view`, `:ecto`, `:otp`, or `:unknown`.
- `TestLens.Impact` — stub for changed-files / affected-tests analysis.
- `TestLens.TerminalReporter` — renders the human-readable output and the optional JSON document.
- `TestLens.Rerun` — produces the suggested `mix test --failed` rerun command.
- Adapter stubs under `lib/test_lens/adapters/` for Phoenix, LiveView, Ecto, and OTP.
- Unit tests covering argv parsing, pass-through, classifier, impact stub, config, rerun, terminal reporter, Result event normalisation, EventStore storage, and Formatter event handling.
- `TestLens.ProjectConfig` — loads and validates `.test_lens.exs` from the project root.
- `TestLens.Impact.classify/3` — returns a `%TestLens.Impact{}` struct with `area`, `impact`, `user_facing`, `critical`, and `reason` fields.
- README section on `.test_lens.exs` covering the full schema, loading semantics, priority rules, safety guarantees, and a small extending example.
