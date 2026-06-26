defmodule TestLens.HTMLReport do
  @moduledoc """
  Builds and writes the TestLens HTML report for review artifacts.

  ## What this is

  When you run `mix test.lens --html` (or `mix test.lens --html-file PATH`),
  TestLens writes a self-contained HTML file containing the same normalised
  data as the terminal and JSON reports. The HTML is:

  - **Self-contained** — no external CSS, no JavaScript, no web fonts.
  - **Print-friendly** — attaches cleanly to a PR, issue, or agent review.
  - **Semantic** — uses `<header>`, `<section>`, `<details>`, `<table>`, etc.
  - **Reviewable** — sections in priority order: summary first, critical
    failures next, then groupings, then raw failure details.

  ## Default location

  `_build/test_lens/report.html` (relative to the project root).

  ## Sections (in order)

  1. **Summary** — total counts (tests/passed/failed/skipped/excluded/invalid)
     and run time.
  2. **Critical failures** — failures whose `classification.default_severity`
     is `:critical`. If none, the section is omitted.
  3. **Failures by area** — group counts by `impact.area`. Areas with zero
     failures are not listed.
  4. **Failures by type** — group counts by `classification.type`. Same shape
     as the JSON `classification_counts`.
  5. **Slow tests** — top 5 by `time_us`.
  6. **Suggested reruns** — the same `next_commands` list as the JSON.
  7. **Raw failure details** — one `<details>` per failure with module, name,
     file, classification, impact, and the raw failure body (best-effort
     extracted from `result.failures`).

  ## What is NOT included

  No environment variables. No `Mix.Project.config/0`. No ExUnit logs.
  No application config. Same discipline as the JSON artifact.

  ## Stability

  Section order and section IDs are part of the 1.0.0 contract. Section
  contents may gain fields in minor versions; section structure is stable.
  The underlying JSON artifact carries a `schema_version` field; the HTML
  renders the same TestLens version string in `<meta name="generator">`.
  """

  alias TestLens.{Classifier, Impact, ProjectConfig, Result}

  @default_path "_build/test_lens/report.html"

  @doc "Returns the default artifact path."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc """
  Builds the HTML report as a complete document (string). Pure function.
  """
  @spec build([Result.t()], map(), integer() | :random | nil) :: String.t()
  def build(results, times_us, seed) do
    failed = Enum.filter(results, &Result.failed?/1)
    config = ProjectConfig.load_or_default()
    project = config.project

    [
      doctype(),
      html_open(),
      head(project, results, seed, times_us),
      body_open(),
      header(project, results, seed, times_us),
      summary_section(results, times_us),
      critical_failures_section(failed),
      failures_by_area_section(failed),
      failures_by_type_section(failed),
      slow_tests_section(results),
      suggested_reruns_section(results, seed),
      raw_failure_details_section(failed),
      footer(),
      body_close(),
      html_close()
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Builds and writes the HTML report to `path`. Creates parent directories
  if they do not exist. Returns `:ok` on success or `{:error, reason}`.
  """
  @spec write(Path.t(), [Result.t()], map(), integer() | :random | nil) ::
          :ok | {:error, term()}
  def write(path, results, times_us, seed) do
    html = build(results, times_us, seed)

    try do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, html)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Document skeleton
  # ---------------------------------------------------------------------------

  defp doctype, do: "<!DOCTYPE html>\n"

  defp html_open, do: ~s(<html lang="en">\n)

  defp html_close, do: "</html>\n"

  defp body_open, do: "<body>\n"
  defp body_close, do: "</body>\n"

  defp head(project, results, seed, times_us) do
    title = build_title(project, results, seed, times_us)

    [
      ~s(<head>\n),
      ~s(  <meta charset="utf-8">\n),
      ~s(  <meta name="viewport" content="width=device-width, initial-scale=1">\n),
      ~s(  <meta name="generator" content="TestLens #{TestLens.version()}">\n),
      ~s(  <title>) <> escape_html(title) <> "</title>\n",
      ~s(  <style>\n),
      css(),
      ~s(  </style>\n),
      ~s(</head>\n)
    ]
  end

  defp build_title(project, results, seed, _times_us) do
    project_str = project || "TestLens"
    passed = Enum.count(results, &Result.passed?/1)
    failed = Enum.count(results, &Result.failed?/1)

    seed_str =
      case seed do
        n when is_integer(n) -> " — seed #{n}"
        :random -> " — seed random"
        _ -> ""
      end

    "#{project_str} — #{passed} passed, #{failed} failed#{seed_str}"
  end

  # ---------------------------------------------------------------------------
  # CSS — inline, no external assets
  # ---------------------------------------------------------------------------

  defp css do
    """
    :root {
      color-scheme: light dark;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      max-width: 1100px;
      margin: 0 auto;
      padding: 2rem 1.5rem;
      color: #1a1a1a;
      background:
        radial-gradient(circle at top left, rgba(10, 125, 44, 0.10), transparent 28rem),
        radial-gradient(circle at top right, rgba(196, 49, 75, 0.10), transparent 24rem),
        #fafafa;
      line-height: 1.5;
    }
    @media (prefers-color-scheme: dark) {
      body {
        color: #e6e6e6;
        background:
          radial-gradient(circle at top left, rgba(49, 196, 105, 0.14), transparent 28rem),
          radial-gradient(circle at top right, rgba(255, 92, 124, 0.13), transparent 24rem),
          #161616;
      }
      pre, code { background: #1f1f1f; }
      .card { background: #1f1f1f; }
      .panel, .hero { background: rgba(31, 31, 31, 0.92); }
      th { background: #262626; }
    }
    h1, h2, h3 { color: inherit; }
    h1 { margin: 0 0 0.25rem 0; font-size: 1.75rem; }
    h2 { margin: 2rem 0 0.75rem 0; padding-bottom: 0.4rem;
         border-bottom: 1px solid #d0d0d0; font-size: 1.25rem; }
    h3 { margin: 1.25rem 0 0.5rem 0; font-size: 1rem; }
    p, ul, ol { margin: 0.5rem 0; }
    code, pre {
      font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.875rem;
    }
    code { background: #ececec; padding: 0.05rem 0.35rem; border-radius: 3px; }
    pre { background: #ececec; padding: 0.75rem; border-radius: 6px;
          overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; }
    .muted { color: #6a6a6a; }
    .passed { color: #0a7d2c; font-weight: 500; }
    .failed { color: #c4314b; font-weight: 500; }
    .skipped { color: #806000; }
    .critical { color: #c4314b; font-weight: 600; }
    .other { color: #6a6a6a; }
    .tag { display: inline-block; background: #e6e6e6; color: #333;
           padding: 0.05rem 0.45rem; border-radius: 3px; font-size: 0.8rem;
           margin: 0 0.15rem 0.15rem 0; }
    .meta { color: #6a6a6a; font-size: 0.875rem; }
    .card { background: #ffffff; border: 1px solid #d0d0d0;
            border-radius: 6px; padding: 0.75rem 1rem; margin: 0.5rem 0; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 0.5rem; margin: 0.5rem 0; }
    .stat { background: #ffffff; border: 1px solid #d0d0d0;
            border-radius: 6px; padding: 0.5rem 0.75rem; }
    .stat .num { font-size: 1.5rem; font-weight: 600; }
    .stat .label { font-size: 0.75rem; color: #6a6a6a; text-transform: uppercase;
                   letter-spacing: 0.05em; }
    table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; }
    th, td { padding: 0.4rem 0.6rem; text-align: left; border-bottom: 1px solid #e6e6e6; }
    th { background: #f0f0f0; font-weight: 600; }
    details { background: #ffffff; border: 1px solid #d0d0d0;
              border-radius: 6px; padding: 0.5rem 0.75rem; margin: 0.4rem 0; }
    details[open] { padding-bottom: 0.75rem; }
    summary { cursor: pointer; font-weight: 500; }
    summary::-webkit-details-marker { margin-right: 0.5rem; }
    a { color: #0a5dc2; text-decoration: none; }
    a:hover { text-decoration: underline; }
    footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #d0d0d0;
             color: #6a6a6a; font-size: 0.8rem; }
    .hero {
      position: relative;
      overflow: hidden;
      padding: 1.4rem 1.5rem;
      border: 1px solid #d0d0d0;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.92);
      box-shadow: 0 16px 40px rgba(0, 0, 0, 0.08);
    }
    .hero::before {
      content: "";
      position: absolute;
      inset: 0;
      border-top: 6px solid #6a6a6a;
      pointer-events: none;
    }
    .hero-pass::before { border-top-color: #0a7d2c; }
    .hero-fail::before { border-top-color: #c4314b; }
    .hero-skip::before { border-top-color: #b77900; }
    .eyebrow { margin: 0 0 0.2rem; color: #6a6a6a; font-size: 0.8rem;
               letter-spacing: 0.12em; text-transform: uppercase; }
    .hero h1 { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 0.4rem;
               font-size: clamp(2rem, 4vw, 3rem); }
    .hero-icon { display: inline-grid; place-items: center; width: 2.1rem; height: 2.1rem;
                 border-radius: 999px; color: white; background: #6a6a6a; font-size: 1.35rem; }
    .hero-pass .hero-icon { background: #0a7d2c; }
    .hero-fail .hero-icon { background: #c4314b; }
    .hero-skip .hero-icon { background: #b77900; }
    .hero-meta { color: #6a6a6a; margin: 0.25rem 0; }
    .hero-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr));
                  gap: 0.5rem; margin: 1rem 0 0.75rem; }
    .hero-stat { border: 1px solid #d0d0d0; border-radius: 12px; padding: 0.6rem 0.75rem;
                 background: rgba(255, 255, 255, 0.7); }
    .hero-stat span { display: block; font-size: 1.55rem; font-weight: 700; line-height: 1; }
    .hero-stat small { color: #6a6a6a; text-transform: uppercase; letter-spacing: 0.08em; }
    .hero-stat.passed span { color: #0a7d2c; }
    .hero-stat.failed span { color: #c4314b; }
    .hero-stat.skipped span { color: #806000; }
    .progress-meter { display: flex; overflow: hidden; height: 0.8rem; border-radius: 999px;
                      background: #e6e6e6; border: 1px solid #d0d0d0; }
    .progress-pass { background: #0a7d2c; }
    .progress-fail { background: #c4314b; }
    .progress-rest, .progress-empty { background: #c8c8c8; }
    .panel {
      background: rgba(255, 255, 255, 0.92);
      border: 1px solid #d0d0d0;
      border-radius: 16px;
      padding: 1rem 1.1rem;
      margin-top: 1rem;
      box-shadow: 0 10px 26px rgba(0, 0, 0, 0.04);
    }
    .panel h2 { margin-top: 0; }
    .critical-panel { border-color: rgba(196, 49, 75, 0.45); }
    .command-panel code { font-weight: 700; }
    .failure-card { border-left: 5px solid #6a6a6a; }
    .failure-card.severity-critical { border-left-color: #c4314b; }
    .failure-card.severity-other { border-left-color: #b77900; }
    .failure-detail { border-left: 4px solid #d0d0d0; }
    @media (prefers-color-scheme: dark) {
      .hero, .panel, .stat, .hero-stat, .card, details {
        background: rgba(31, 31, 31, 0.92);
        border-color: #3a3a3a;
      }
      .progress-meter { background: #2a2a2a; border-color: #3a3a3a; }
      .progress-rest, .progress-empty { background: #505050; }
      .critical-panel { border-color: rgba(255, 92, 124, 0.45); }
      .failure-detail { border-left-color: #3a3a3a; }
    }
    @media print {
      body { background: white; max-width: none; padding: 0.5rem; }
      .card, details, .stat, table { box-shadow: none; }
      details { page-break-inside: avoid; }
      h2 { page-break-after: avoid; }
    }
    """
  end

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  defp header(project, results, seed, times_us) do
    timestamp = format_timestamp(DateTime.utc_now())
    project_str = project || "TestLens"
    passed = Enum.count(results, &Result.passed?/1)
    failed = Enum.count(results, &Result.failed?/1)
    skipped = Enum.count(results, &Result.skipped?/1)
    total = length(results)
    outcome = outcome_class(failed, skipped, total)

    seed_str =
      case seed do
        n when is_integer(n) -> "seed: #{n}"
        :random -> "seed: random"
        _ -> ""
      end

    time_str = format_times(times_us)

    [
      "<header class=\"hero hero-" <> outcome <> "\">\n",
      "  <p class=\"eyebrow\">" <> escape_html(project_str) <> "</p>\n",
      "  <h1><span class=\"hero-icon\">" <>
        outcome_icon(outcome) <> "</span> TestLens report</h1>\n",
      "  <p class=\"hero-meta\">" <>
        escape_html(project_str) <>
        " · " <> escape_html(timestamp) <> " · " <> escape_html(seed_str) <> "</p>\n",
      "  <div class=\"hero-stats\">\n",
      hero_stat(passed, "passed", "passed"),
      hero_stat(failed, "failed", "failed"),
      hero_stat(skipped, "skipped", "skipped"),
      hero_stat(total, "total", "muted"),
      "  </div>\n",
      "  <p class=\"hero-meta\">Run time: " <> escape_html(time_str) <> "</p>\n",
      progress_bar(passed, failed, total),
      "</header>\n"
    ]
  end

  defp summary_section(results, times_us) do
    counts = %{
      tests: length(results),
      passed: Enum.count(results, &Result.passed?/1),
      failed: Enum.count(results, &Result.failed?/1),
      skipped: Enum.count(results, &Result.skipped?/1),
      excluded: Enum.count(results, fn r -> r.status == :excluded end),
      invalid: Enum.count(results, fn r -> r.status == :invalid end)
    }

    time_str = format_times(times_us)

    stat = fn num, label, klass ->
      klass_attr = if klass != "", do: " class=\"" <> klass <> "\"", else: ""

      [
        "    <div class=\"stat\">\n",
        "      <div" <> klass_attr <> ">" <> Integer.to_string(num) <> "</div>\n",
        "      <div class=\"label\">" <> label <> "</div>\n",
        "    </div>\n"
      ]
    end

    [
      "<section id=\"summary\" class=\"panel summary-panel\">\n",
      "  <h2>Summary</h2>\n",
      "  <div class=\"grid\">\n",
      stat.(counts.tests, "tests", ""),
      stat.(counts.passed, "passed", "passed"),
      stat.(counts.failed, "failed", "failed"),
      stat.(counts.skipped, "skipped", "skipped"),
      stat.(counts.excluded, "excluded", "muted"),
      stat.(counts.invalid, "invalid", "muted"),
      "  </div>\n",
      "  <p class=\"meta\">Total run time: " <> escape_html(time_str) <> "</p>\n",
      "</section>\n"
    ]
  end

  defp critical_failures_section([]), do: ""

  defp critical_failures_section(failures) do
    critical =
      Enum.filter(failures, fn r ->
        tuple = to_failure_tuple(r)

        case Classifier.classify_failure(tuple) do
          %{default_severity: :critical} -> true
          _ -> false
        end
      end)

    if critical == [] do
      ""
    else
      [
        "<section id=\"critical-failures\" class=\"panel critical-panel\">\n",
        "  <h2>Critical failures (#{length(critical)})</h2>\n",
        Enum.map(critical, &failure_card(&1, "critical")),
        "</section>\n"
      ]
    end
  end

  defp failures_by_area_section([]), do: ""

  defp failures_by_area_section(failures) do
    by_area =
      failures
      |> Enum.group_by(fn r -> Impact.classify(r) end)
      |> Enum.map(fn {impact, list} -> {impact.area || "(no area)", list} end)
      |> Enum.sort_by(fn {_area, list} -> -length(list) end)

    [
      "<section id=\"failures-by-area\" class=\"panel\">\n",
      "  <h2>Failures by area</h2>\n",
      failure_grouping_table(by_area),
      "</section>\n"
    ]
  end

  defp failures_by_type_section([]), do: ""

  defp failures_by_type_section(failures) do
    by_type =
      failures
      |> Enum.map(fn r ->
        tuple = to_failure_tuple(r)

        tuple
        |> Classifier.classify_failure()
        |> Map.fetch!(:type)
        |> Atom.to_string()
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_type, count} -> -count end)

    [
      "<section id=\"failures-by-type\" class=\"panel\">\n",
      "  <h2>Failures by type</h2>\n",
      type_table(by_type),
      "</section>\n"
    ]
  end

  defp slow_tests_section(results) do
    slow =
      results
      |> Enum.filter(fn r -> r.time_us > 0 end)
      |> Enum.sort_by(& &1.time_us, :desc)
      |> Enum.take(5)

    if slow == [] do
      ""
    else
      [
        "<section id=\"slow-tests\" class=\"panel\">\n",
        "  <h2>Slow tests (top 5)</h2>\n",
        "  <table>\n",
        "    <thead><tr><th>Time</th><th>Module</th><th>Test</th><th>File</th></tr></thead>\n",
        "    <tbody>\n",
        Enum.map(slow, fn r ->
          [
            "      <tr>\n",
            "        <td><code>" <> format_time_us(r.time_us) <> "</code></td>\n",
            "        <td>" <> escape_html(inspect(r.module)) <> "</td>\n",
            "        <td>" <> escape_html(Atom.to_string(r.name)) <> "</td>\n",
            "        <td>" <> escape_html(r.file || "") <> "</td>\n",
            "      </tr>\n"
          ]
        end),
        "    </tbody>\n",
        "  </table>\n",
        "</section>\n"
      ]
    end
  end

  defp suggested_reruns_section(results, seed) do
    cmds = compute_next_commands(results, seed)

    if cmds == [] do
      ""
    else
      [
        "<section id=\"suggested-reruns\" class=\"panel command-panel\">\n",
        "  <h2>Suggested reruns</h2>\n",
        "  <ul>\n",
        Enum.map(cmds, fn {command, comment} ->
          [
            "    <li><code>" <> escape_html(command) <> "</code>",
            if comment != "" do
              " <span class=\"muted\">— " <> escape_html(comment) <> "</span>"
            else
              ""
            end,
            "</li>\n"
          ]
        end),
        "  </ul>\n",
        "</section>\n"
      ]
    end
  end

  defp raw_failure_details_section([]), do: ""

  defp raw_failure_details_section(failures) do
    [
      "<section id=\"raw-failure-details\" class=\"panel\">\n",
      "  <h2>Raw failure details (#{length(failures)})</h2>\n",
      "  <p class=\"meta\">Open each entry for the full classification, impact, and raw failure body.</p>\n",
      Enum.map(failures, &raw_failure_details/1),
      "</section>\n"
    ]
  end

  defp raw_failure_details(r) do
    classification = Classifier.classify_failure(to_failure_tuple(r))
    impact = Impact.classify(r)
    raw_body = format_raw_failures(r)
    sev = Atom.to_string(classification.default_severity)
    sev_class = if sev == "critical", do: "critical", else: "other"

    [
      "<details class=\"failure-detail\">\n",
      "  <summary>",
      escape_html(inspect(r.module)),
      " · " <> escape_html(Atom.to_string(r.name)),
      " <span class=\"" <> sev_class <> "\">[" <> escape_html(sev) <> "]</span>",
      if r.file do
        " <span class=\"muted\">— " <> escape_html(r.file) <> "</span>"
      else
        ""
      end,
      "</summary>\n",
      "  <h3>Classification</h3>\n",
      "  <table>\n",
      kv_row("Type", Atom.to_string(classification.type)),
      kv_row("Likely layer", classification.likely_layer),
      kv_row("Plain English", classification.plain_english),
      kv_row("Default severity", sev),
      "  </table>\n",
      if classification.common_causes != [] do
        [
          "  <h3>Common causes</h3>\n",
          "  <ul>" <> causes_list(classification.common_causes) <> "</ul>\n"
        ]
      else
        ""
      end,
      if classification.suggested_checks != [] do
        [
          "  <h3>Suggested checks</h3>\n",
          "  <ul>" <> causes_list(classification.suggested_checks) <> "</ul>\n"
        ]
      else
        ""
      end,
      "  <h3>Impact</h3>\n",
      "  <table>\n",
      kv_row("Area", impact.area || "(none)"),
      kv_row("Impact", Atom.to_string(impact.impact)),
      kv_row("User-facing", to_string(impact.user_facing)),
      kv_row("Critical", to_string(impact.critical)),
      kv_row("Reason", impact.reason),
      "  </table>\n",
      if r.tags != %{} do
        [
          "  <h3>Tags</h3>\n",
          "  <p>" <> tag_list(r.tags) <> "</p>\n"
        ]
      else
        ""
      end,
      if raw_body != "" do
        [
          "  <h3>Raw failure</h3>\n",
          "  <pre>" <> escape_html(raw_body) <> "</pre>\n"
        ]
      else
        ""
      end,
      "</details>\n"
    ]
  end

  # ---------------------------------------------------------------------------
  # Building blocks
  # ---------------------------------------------------------------------------

  defp failure_card(r, severity_class) do
    classification = Classifier.classify_failure(to_failure_tuple(r))
    impact = Impact.classify(r)
    type_str = Atom.to_string(classification.type)

    [
      "  <div class=\"card failure-card severity-" <> severity_class <> "\">\n",
      "    <p><strong>" <> escape_html(inspect(r.module)) <> "</strong>\n",
      "      <span class=\"muted\"> · </span>\n",
      escape_html(Atom.to_string(r.name)),
      "      <span class=\"" <>
        severity_class <> "\"> [" <> escape_html(severity_class) <> "]</span>\n",
      "    </p>\n",
      if r.file do
        "    <p class=\"meta\">file: " <> escape_html(r.file) <> "</p>\n"
      else
        ""
      end,
      "    <p class=\"meta\">type: <code>" <>
        escape_html(type_str) <>
        "</code> · layer: " <> escape_html(classification.likely_layer) <> "</p>\n",
      "    <p class=\"meta\">impact: <code>" <>
        escape_html(Atom.to_string(impact.impact)) <>
        "</code> · area: " <>
        escape_html(impact.area || "(none)") <>
        " · user_facing: " <> to_string(impact.user_facing) <> "</p>\n",
      if r.tags != %{} do
        "    <p>" <> tag_list(r.tags) <> "</p>\n"
      else
        ""
      end,
      "  </div>\n"
    ]
  end

  defp failure_grouping_table([]), do: "  <p class=\"muted\">No failures.</p>\n"

  defp failure_grouping_table(by_area) do
    [
      "  <table>\n",
      "    <thead><tr><th>Area</th><th>Failures</th></tr></thead>\n",
      "    <tbody>\n",
      Enum.map(by_area, fn {area, list} ->
        "      <tr><td>" <>
          escape_html(area) <> "</td><td>" <> Integer.to_string(length(list)) <> "</td></tr>\n"
      end),
      "    </tbody>\n",
      "  </table>\n"
    ]
  end

  defp type_table([]), do: "  <p class=\"muted\">No failures.</p>\n"

  defp type_table(by_type) do
    [
      "  <table>\n",
      "    <thead><tr><th>Type</th><th>Count</th></tr></thead>\n",
      "    <tbody>\n",
      Enum.map(by_type, fn {type, count} ->
        "      <tr><td><code>" <>
          escape_html(type) <> "</code></td><td>" <> Integer.to_string(count) <> "</td></tr>\n"
      end),
      "    </tbody>\n",
      "  </table>\n"
    ]
  end

  defp kv_row(key, value) do
    "    <tr><th>" <> escape_html(key) <> "</th><td>" <> escape_html(value) <> "</td></tr>\n"
  end

  defp causes_list(items) do
    Enum.map_join(items, "", fn item ->
      "<li>" <> escape_html(item) <> "</li>"
    end)
  end

  defp tag_list(tags) when is_map(tags) do
    Enum.map_join(tags, "", fn {k, v} ->
      label = if v === true, do: Atom.to_string(k), else: "#{k}=#{v}"
      "<span class=\"tag\">" <> escape_html(label) <> "</span>"
    end)
  end

  defp tag_list(_), do: ""

  defp footer do
    [
      "<footer>\n",
      "  <p>Generated by <a href=\"https://github.com/Tenvia/test_lens\">TestLens " <>
        escape_html(TestLens.version()) <> "</a></p>\n",
      "  <p class=\"meta\">Schema is part of the v0.1.x contract. This report is self-contained: no external CSS, no JavaScript, no web fonts.</p>\n",
      "</footer>\n"
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp outcome_class(failed, _skipped, _total) when failed > 0, do: "fail"
  defp outcome_class(0, skipped, _total) when skipped > 0, do: "skip"
  defp outcome_class(0, 0, 0), do: "neutral"
  defp outcome_class(0, 0, _total), do: "pass"

  defp outcome_icon("fail"), do: "✗"
  defp outcome_icon("skip"), do: "»"
  defp outcome_icon("pass"), do: "✓"
  defp outcome_icon(_), do: "·"

  defp hero_stat(num, label, klass) do
    [
      "    <div class=\"hero-stat ",
      escape_html(klass),
      "\"><span>",
      Integer.to_string(num),
      "</span><small>",
      escape_html(label),
      "</small></div>\n"
    ]
  end

  defp progress_bar(_passed, _failed, 0) do
    "  <div class=\"progress-meter\" aria-label=\"No tests recorded\"><span class=\"progress-empty\" style=\"width: 100%\"></span></div>\n"
  end

  defp progress_bar(passed, failed, total) do
    passed_pct = Float.round(passed / total * 100, 2)
    failed_pct = Float.round(failed / total * 100, 2)
    rest_pct = max(Float.round(100 - passed_pct - failed_pct, 2), 0)

    [
      "  <div class=\"progress-meter\" aria-label=\"Test result ratio\">",
      "<span class=\"progress-pass\" style=\"width: #{passed_pct}%\"></span>",
      "<span class=\"progress-fail\" style=\"width: #{failed_pct}%\"></span>",
      "<span class=\"progress-rest\" style=\"width: #{rest_pct}%\"></span>",
      "</div>\n"
    ]
  end

  defp to_failure_tuple(%Result{failures: [first | _]} = _r) when is_tuple(first) do
    case first do
      {kind, reason, stack} when is_atom(kind) -> {kind, reason, stack}
      _ -> {:error, nil, []}
    end
  end

  defp to_failure_tuple(%Result{status: :invalid}), do: {:invalid, nil, []}
  defp to_failure_tuple(%Result{}), do: {:error, nil, []}

  defp format_raw_failures(%Result{failures: fs}) when is_list(fs) do
    fs
    |> Enum.map(fn
      {kind, reason, stack} ->
        stack_str = stack |> Enum.take(10) |> Enum.map_join("\n", &format_stack_frame/1)
        kind_str = Atom.to_string(kind)
        reason_str = safe_exception_message(reason)
        "[#{kind_str}] #{reason_str}\n#{stack_str}"

      other ->
        inspect(other)
    end)
    |> Enum.join("\n\n")
  end

  defp format_raw_failures(_), do: ""

  defp safe_exception_message(term) do
    try do
      Exception.message(term)
    rescue
      _ -> inspect(term)
    end
  end

  defp format_stack_frame({mod, fun, arity_or_args, _loc}) do
    inspect(mod) <> "." <> Atom.to_string(fun) <> "/" <> inspect(arity_or_args)
  end

  defp format_stack_frame(other), do: inspect(other)

  defp format_times(times_us) when is_map(times_us) do
    total_us =
      (times_us |> Map.get(:run, 0) |> Kernel.||(0)) +
        (times_us |> Map.get(:async, 0) |> Kernel.||(0))

    cond do
      total_us >= 1_000_000 -> "#{Float.round(total_us / 1_000_000, 2)}s"
      total_us >= 1_000 -> "#{Float.round(total_us / 1_000, 1)}ms"
      total_us > 0 -> "#{total_us}µs"
      true -> "—"
    end
  end

  defp format_times(_), do: "—"

  defp format_time_us(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> "#{Float.round(us / 1_000_000, 2)}s"
      us >= 1_000 -> "#{Float.round(us / 1_000, 1)}ms"
      true -> "#{us}µs"
    end
  end

  defp format_time_us(_), do: "—"

  defp format_timestamp(dt) do
    {{y, mo, d}, {h, mi, s}} = dt |> DateTime.to_naive() |> NaiveDateTime.to_erl()

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B UTC", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp compute_next_commands(results, seed) do
    cmds = []

    cmds =
      if Enum.any?(results, &Result.failed?/1) do
        [{"mix test.lens -- --failed", "rerun the failing tests"} | cmds]
      else
        cmds
      end

    cmds = [{"mix test.lens -- --stale", "check for stale tests"} | cmds]

    case seed do
      n when is_integer(n) ->
        [{"mix test.lens -- --seed #{n}", "reproduce this run"} | cmds]

      _ ->
        cmds
    end
    |> Enum.reverse()
  end

  # HTML-escape: replace the four characters that need escaping in text
  # content and attribute values. We hand-build the markup, so we
  # know which fragments are text.
  defp escape_html(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(other), do: escape_html(to_string(other))
end
