# Changelog

All notable changes to TestLens will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `mix format` configuration (`.formatter.exs`); CI runs `mix format --check-formatted`.
- `mix credo` configuration (`.credo.exs`); CI runs `mix credo --strict`.
- GitHub Actions CI workflow (`.github/workflows/ci.yml`) testing Elixir 1.18/1.19 × OTP 27/28.
- `CONTRIBUTING.md` — how to file bugs, request features, and add new classifier/adapter modules.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1).
- `.github/ISSUE_TEMPLATE/` — bug report, classification request, adapter request, report output feedback.
- `fixtures/` — sample TTY, JSON, and HTML outputs as living examples of the report shapes.
- `.tool-versions` — pins Elixir 1.19.5 and OTP 28.0 for asdf.

### Changed

- `README.md` reorganised: explicit "What TestLens is" / "What it is not" / "How TestLens differs from" sections, prominent "Why impact config matters" framing, CI integration subsection, contributing pointer.
- All source code formatted with `mix format`.
- `TestLens.TerminalReporter.render_failure_block/2` now calls
  `TestLens.Impact.classify/1` to populate the per-failure `impact:`
  and `area:` fields instead of the v0.1.0 `unknown` placeholder. JSON
  and HTML reporters were already wired. The `layer:` field was
  already wired to `TestLens.Classifier.classify/1`. Three regression
  tests under a new `render_failures/2 with TestLens.Impact wiring`
  describe block in `terminal_reporter_test.exs` lock the wiring in
  (one per scenario: matched area, unmatched area, hardcoded-`unknown`
  regression).
- `TestLens.Impact.find_area/2` now relativises the test file path
  via `Path.relative_to_cwd/1` before the `String.starts_with?/2`
  prefix check. `ExUnit.TestModule.file` is an absolute path; the
  consumer's `.test_lens.exs` area keys are relative to cwd. Without
  this, every consumer saw `area: (no area)` and `impact: none`
  regardless of their config. The function is now `def` (was `defp`)
  so the new regression tests in `impact_test.exs` can call it
  directly.

## [0.1.0] - 2026-06-24

### Changed

- `TestLens.TerminalReporter` rewrite: suite status now includes seed, failures
  are severity-grouped (Critical/Other), slow tests section shows top 5,
  next commands section provides suggested rerun commands.
- Failure block now includes file, type, layer, impact, and rerun command.
- `TestLens.Formatter` captures seed from ExUnit options and forwards it to
  `TerminalReporter.render/4`. The EventStore server reference is now read
  from `Application.get_env(:test_lens, :event_store, TestLens.EventStore)`
  so tests can isolate the store. The formatter no longer resets the
  EventStore on `suite_started` — ExUnit may start the formatter more than
  once within a single run, and resetting would erase accumulated results.
  Rendering still happens exactly once, on the first `suite_finished` that
  carries the `:run` key.

### Added

- `--json` now writes a structured JSON artifact file (default `_build/test_lens/report.json`).
- `--json-file PATH` overrides the artifact path.
- `TestLens.JSONReport` is the new module that builds the artifact. Schema is documented in its moduledoc and is part of the v0.1.0 contract.
- `--html` and `--html-file PATH` write a self-contained HTML report (no external assets, no JavaScript) for PR/issue/agent-review attachments.
- `TestLens.HTMLReport` is the new module that builds the HTML report. Section order and IDs are part of the v0.1.x contract.
- `TestLens.Classifier.classify_failure/1` returns a deterministic classification map (`type`, `likely_layer`, `plain_english`, `common_causes`, `suggested_checks`, `default_severity`) for an ExUnit failure tuple `{kind, reason, stacktrace}`.
- 13 new failure adapter modules under `lib/test_lens/failure_adapters/` covering the common Elixir/Phoenix/OTP/Ecto failure shapes.
- `TestLens.Classifier.register_failure_adapter/1` lets consumers prepend a user adapter to the priority list.
- Initial project scaffolding.
- `mix test.lens` task that delegates to `mix test` while injecting the
  `TestLens.Formatter`. Arguments before `--` are TestLens-specific; arguments
  after `--` are passed through unchanged to `mix test`.
- `TestLens.Formatter` — a thin ExUnit formatter (`use GenServer`) that
  normalises events into `TestLens.Result` records, captures module-level
  start/finish events in the EventStore, and renders a TestLens report
  at `suite_finished`. Designed to be a pure normalisation layer — no
  business-impact decisions.
- `TestLens.Config` — runtime configuration loaded from TestLens CLI flags.
  `--json` forces JSON output; `--no-color` disables ANSI colour.
- `TestLens.Result` — normalised per-test result record. Captures test
  name/module/file/tags/status/failures/duration from the raw
  `%ExUnit.Test{}` plus the most recent `%ExUnit.TestModule{}` for the
  file path. Raw failure 3-tuples are preserved verbatim for later
  rendering and rerun command generation.
- `TestLens.EventStore` — Agent-based store. Holds per-test Results
  (in arrival order) and per-module events (`%{event, name, file, state}`
  for `:started` and `:finished`). Exposes `put_result/2`, `get_results/1`,
  `put_module_event/2`, `get_module_events/1`, `module_names/1`,
  `latest_module_event/2`, `count/1`, `count_by_status/2`, `reset/1`,
  and `put/2`/`get/1` aliases.
- `TestLens.Classifier` — categorises tests into `:unit`, `:integration`,
  `:phoenix`, `:live_view`, `:ecto`, `:otp`, or `:unknown`.
- `TestLens.Impact` — stub for changed-files / affected-tests analysis.
- `TestLens.TerminalReporter` — renders the human-readable output and
  the optional JSON document (no external encoding dependency).
- `TestLens.Rerun` — produces the suggested `mix test --failed` rerun command.
- Adapter stubs under `lib/test_lens/adapters/` for Phoenix, LiveView, Ecto,
  and OTP.
- Unit tests covering argv parsing, pass-through, classifier, impact stub,
  config, rerun, terminal reporter, **Result event normalisation,
  EventStore storage, and Formatter event handling**.
- `TestLens.ProjectConfig` — loads and validates `.test_lens.exs` from the
  project root. Safe fallback to an empty config on missing or invalid files.
  Module docs explain the "project config supplies meaning, TestLens supplies
  structure" design contract.
- `TestLens.Impact.classify/3` — returns a `%TestLens.Impact{}` struct with
  `area`, `impact`, `user_facing`, `critical`, and `reason` fields. Critical
  tags (from `.test_lens.exs`) override area matching; area match falls back
  to a default `:none` impact. The existing `changed_files_since/1` and
  `affected_tests/2` stubs remain unchanged as the v0.1.0 contract.
- README section on `.test_lens.exs` covering the full schema, loading
  semantics, priority rules, safety guarantees, and a small extending example.