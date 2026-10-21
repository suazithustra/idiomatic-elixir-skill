defmodule Evals.SkillCheck do
  @moduledoc """
  Checks the skill's Elixir examples and the coverage index in this folder.

  Run it as `elixir evals/check_skill.exs`; the script resolves its own paths, so it works
  from any directory. It exits 1 when any check fails. `check_skill_test.exs` loads this
  file for its fixture tests without running the checks.
  """

  @repo_root Path.expand("..", __DIR__)
  @skill_dir "idiomatic-elixir"
  @skill_file "SKILL.md"
  @references_dir "references"
  @readme Path.join(["evals", "README.md"])

  # Both examples end in an open `do` to show one line of a longer function, so they
  # cannot parse and are reported as skipped instead of failed.
  @fragments [
    {@skill_file, "Use `and`, `or`, `not` when the operands are booleans"},
    {@skill_file, "Comments explain why; documentation goes in `@moduledoc` and `@doc`"}
  ]

  # A wrong-then-right block is two snippets. The formatter would insert a blank line
  # before the second comment, which the examples do not want, so each part is
  # formatted on its own.
  @marker ~r/^# (Instead of|write|or)(?![A-Za-z])/

  @bullet_sections ["Naming", "Before you finish"]
  @list_headings ["Other ExUnit features to reach for"]

  @type block :: %{
          file: String.t(),
          heading: String.t() | nil,
          ordinal: pos_integer(),
          code: String.t()
        }
  @type finding :: %{
          file: String.t(),
          heading: String.t() | nil,
          ordinal: pos_integer(),
          tier: :parse | :format | :compile,
          part: String.t() | nil,
          reason: String.t()
        }
  @type index_row :: %{rule: String.t(), cases: String.t()}
  @type phrase_row :: %{file: String.t(), phrase: String.t()}
  @type phrase_finding :: %{
          phrase: String.t(),
          file: String.t(),
          in_file: non_neg_integer(),
          total: non_neg_integer()
        }
  @type coverage :: %{
          missing: [String.t()],
          orphans: [String.t()],
          none_yet: [String.t()],
          unexplained: [String.t()],
          not_provocable: [String.t()]
        }

  @spec run(Path.t()) :: 0 | 1
  def run(root \\ @repo_root) do
    contents = skill_contents(root)
    readme = File.read!(Path.join(root, @readme))

    block_results =
      for {file, markdown} <- contents, block <- extract_blocks(markdown, file) do
        {block, check_block(block)}
      end

    headings = Enum.flat_map(contents, fn {file, markdown} -> rule_headings(markdown, file) end)
    coverage_report = coverage(headings, index_rows(readme))

    counts = %{
      blocks: print_block_findings(block_results),
      index: print_coverage(coverage_report),
      phrases: print_phrase_findings(phrase_findings(phrase_rows(readme), contents))
    }

    print_summary(block_results, coverage_report, counts)
    if counts.blocks + counts.index + counts.phrases == 0, do: 0, else: 1
  end

  @spec extract_blocks(String.t(), String.t()) :: [block()]
  def extract_blocks(markdown, file) do
    markdown
    |> scan()
    |> Enum.reduce({nil, %{}, []}, fn
      {:heading, _level, text}, {_heading, ordinals, blocks} ->
        {text, ordinals, blocks}

      {:block, code}, {heading, ordinals, blocks} ->
        ordinals = Map.update(ordinals, heading, 1, &(&1 + 1))
        block = %{file: file, heading: heading, ordinal: ordinals[heading], code: code}
        {heading, ordinals, [block | blocks]}

      {:unclosed_fence, language}, {heading, ordinals, blocks} ->
        ordinals = Map.update(ordinals, heading, 1, &(&1 + 1))

        block = %{
          file: file,
          heading: heading,
          ordinal: ordinals[heading],
          code: "",
          unclosed: language
        }

        {heading, ordinals, [block | blocks]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  @spec rule_headings(String.t(), String.t()) :: [String.t()]
  def rule_headings(markdown, file) do
    for {:heading, level, text} <- scan(markdown), rule?(level, text, file), do: text
  end

  defp rule?(3, _text, @skill_file), do: true
  defp rule?(2, text, @skill_file), do: text in @bullet_sections
  defp rule?(2, text, _file), do: text not in @list_headings
  defp rule?(_level, _text, _file), do: false

  defp scan(markdown) do
    {language, _lines, events} =
      markdown
      |> String.split("\n")
      |> Enum.reduce({nil, [], []}, &scan_line/2)

    events = if language, do: [{:unclosed_fence, language} | events], else: events
    Enum.reverse(events)
  end

  defp scan_line("```" <> language, {nil, _lines, events}) do
    {String.trim(language), [], events}
  end

  defp scan_line("```" <> _, {"elixir", lines, events}) do
    code = lines |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
    {nil, [], [{:block, code} | events]}
  end

  defp scan_line("```" <> _, {_language, _lines, events}), do: {nil, [], events}
  defp scan_line(line, {"elixir", lines, events}), do: {"elixir", [line | lines], events}

  defp scan_line(_line, {language, lines, events}) when is_binary(language),
    do: {language, lines, events}

  defp scan_line(line, {nil, lines, events}) do
    case heading(line) do
      {level, text} -> {nil, lines, [{:heading, level, text} | events]}
      nil -> {nil, lines, events}
    end
  end

  defp heading(line) do
    case Regex.run(~r/^(\#{1,6}) (.+)$/, line) do
      [_, hashes, text] -> {String.length(hashes), String.trim(text)}
      nil -> nil
    end
  end

  @spec check_block(block()) :: :ok | :skipped | {:failed, [finding()]}
  def check_block(%{unclosed: language} = block) do
    {:failed, [finding(block, :parse, nil, "the #{language} code fence is never closed")]}
  end

  def check_block(%{file: file, heading: heading} = block) do
    if {file, heading} in @fragments do
      :skipped
    else
      case parse(block.code) do
        :ok -> check_parts(block)
        {:error, reason} -> {:failed, [finding(block, :parse, nil, reason)]}
      end
    end
  end

  defp check_parts(block) do
    findings =
      block.code
      |> split_parts()
      |> Enum.flat_map(fn {part, code} -> check_part(block, part, code) end)

    if findings == [], do: :ok, else: {:failed, findings}
  end

  defp check_part(block, part, code) do
    case format(code) do
      :ok -> compile_if_module(block, part, code)
      {:error, reason} -> [finding(block, :format, part, reason)]
    end
  end

  defp compile_if_module(block, part, code) do
    if defines_module?(code) do
      case compile(code) do
        :ok -> []
        {:error, reason} -> [finding(block, :compile, part, reason)]
      end
    else
      []
    end
  end

  defp split_parts(code) do
    code
    |> String.split("\n")
    |> Enum.reduce([{"block", []}], fn line, [{part, lines} | rest] ->
      case Regex.run(@marker, line) do
        [_, marker] -> [{marker, []}, {part, lines} | rest]
        nil -> [{part, [line | lines]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {part, lines} -> {part, lines |> Enum.reverse() |> Enum.join("\n")} end)
    |> Enum.reject(fn {_part, code} -> String.trim(code) == "" end)
  end

  defp parse(code) do
    Code.string_to_quoted!(code)
    :ok
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, Exception.message(error)}
  end

  defp format(code) do
    formatted = code |> Code.format_string!() |> IO.iodata_to_binary()

    if formatted == String.trim(code) do
      :ok
    else
      {:error, "not formatted; mix format would change it"}
    end
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, Exception.message(error)}
  end

  defp defines_module?(code) do
    {_ast, found?} =
      code
      |> Code.string_to_quoted!()
      |> Macro.prewalk(false, fn
        {name, _meta, _args} = node, _found? when name in [:defmodule, :defprotocol, :defimpl] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp compile(code) do
    names = module_names(code)

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          code |> Code.compile_string() |> Enum.map(&elem(&1, 0)) |> purge()
        rescue
          error -> {:error, Exception.message(error)}
        after
          purge(names)
        end
      end)

    verdict(result, diagnostics)
  end

  # A part that defines two modules loads the first before the second fails to compile,
  # so the names are taken from the source and purged whether or not compilation finished.
  defp module_names(code) do
    {_ast, names} =
      code
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts} | _rest]} = node, names ->
          {node, [Module.concat(parts) | names]}

        node, names ->
          {node, names}
      end)

    names
  end

  defp verdict(:ok, []), do: :ok

  defp verdict(_result, [_ | _] = diagnostics),
    do: {:error, Enum.map_join(diagnostics, "; ", & &1.message)}

  defp verdict({:error, message}, []), do: {:error, message}

  # Compiled examples define real modules in this VM; dropping them keeps one example
  # from shadowing another and leaves nothing behind for the test file.
  defp purge(modules) do
    Enum.each(modules, fn module ->
      :code.delete(module)
      :code.purge(module)
    end)

    :ok
  end

  defp finding(block, tier, part, reason) do
    %{
      file: block.file,
      heading: block.heading,
      ordinal: block.ordinal,
      tier: tier,
      part: part,
      reason: reason
    }
  end

  @spec index_rows(String.t()) :: [index_row()]
  def index_rows(readme) do
    for [rule, cases | _rest] <- table_rows(readme, "| Rule |"), do: %{rule: rule, cases: cases}
  end

  defp phrase_rows(readme) do
    for [file, phrase | _rest] <- table_rows(readme, "| File | Phrase |") do
      %{
        file: Path.join(@references_dir, String.trim(file, "`")),
        phrase: String.trim(phrase, "`")
      }
    end
  end

  defp table_rows(markdown, header_prefix) do
    markdown
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, header_prefix)))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.reject(&String.starts_with?(&1, "| ---"))
    |> Enum.map(&cells/1)
  end

  # A pipe inside a rule heading is written as `\|` in the table, so cells split only on
  # unescaped pipes and the escape is removed afterwards.
  defp cells(row) do
    row
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&String.trim/1)
    |> Enum.drop(1)
    |> Enum.drop(-1)
    |> Enum.map(&String.replace(&1, "\\|", "|"))
  end

  @spec coverage([String.t()], [index_row()]) :: coverage()
  def coverage(headings, rows) do
    rules = Enum.map(rows, & &1.rule)

    %{
      missing: Enum.reject(headings, &(&1 in rules)),
      orphans: Enum.reject(rules, &(&1 in headings)),
      none_yet: for(row <- rows, uncovered?(row.cases), do: row.rule),
      unexplained:
        for(row <- rows, not_provocable?(row.cases) and reason(row.cases) == "", do: row.rule),
      not_provocable:
        for(row <- rows, not_provocable?(row.cases) and reason(row.cases) != "", do: row.rule)
    }
  end

  defp uncovered?(cases), do: cases == "" or String.starts_with?(cases, "none yet")

  defp not_provocable?(cases), do: String.starts_with?(cases, "not provocable")

  defp reason(cases) do
    cases
    |> String.replace_prefix("not provocable", "")
    |> String.trim_leading(":")
    |> String.trim()
  end

  @spec phrase_findings([phrase_row()], %{String.t() => String.t()}) :: [phrase_finding()]
  def phrase_findings(rows, contents) do
    rows
    |> Enum.map(&phrase_counts(&1, contents))
    |> Enum.reject(&(&1.in_file == 1 and &1.total == 1))
  end

  defp phrase_counts(row, contents) do
    %{
      phrase: row.phrase,
      file: row.file,
      in_file: contents |> Map.get(row.file, "") |> String.count(row.phrase),
      total: Enum.sum_by(contents, fn {_file, text} -> String.count(text, row.phrase) end)
    }
  end

  defp skill_contents(root) do
    skill_root = Path.join(root, @skill_dir)

    references =
      skill_root
      |> Path.join("#{@references_dir}/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, skill_root))

    Map.new([@skill_file | references], &{&1, File.read!(Path.join(skill_root, &1))})
  end

  defp print_block_findings(block_results) do
    findings =
      for {_block, {:failed, findings}} <- block_results, finding <- findings, do: finding

    Enum.each(findings, fn finding ->
      part = if finding.part, do: " part \"#{finding.part}\"", else: ""
      fail("#{finding.file} | #{finding.heading} | #{finding.tier}#{part}: #{finding.reason}")
    end)

    length(findings)
  end

  defp print_coverage(coverage) do
    Enum.each(coverage.missing, &fail("#{@readme} | no index row for the rule \"#{&1}\""))
    Enum.each(coverage.orphans, &fail("#{@readme} | index row names no rule heading: \"#{&1}\""))
    Enum.each(coverage.none_yet, &fail("#{@readme} | index row names no case: \"#{&1}\""))

    Enum.each(
      coverage.unexplained,
      &fail("#{@readme} | not provocable row gives no reason: \"#{&1}\"")
    )

    Enum.each(coverage.not_provocable, &IO.puts("SKIP #{@readme} | not provocable: \"#{&1}\""))

    length(coverage.missing) + length(coverage.orphans) + length(coverage.none_yet) +
      length(coverage.unexplained)
  end

  defp print_phrase_findings(findings) do
    Enum.each(findings, fn finding ->
      fail(
        "#{@readme} | phrase \"#{finding.phrase}\" occurs #{finding.in_file} times in #{finding.file} and #{finding.total} times in the skill"
      )
    end)

    length(findings)
  end

  defp print_summary(block_results, coverage, counts) do
    passed = Enum.count(block_results, &match?({_block, :ok}, &1))
    skipped = Enum.count(block_results, &match?({_block, :skipped}, &1))

    IO.puts(
      "#{length(block_results)} blocks: #{passed} passed, #{skipped} skipped, #{counts.blocks} failed; " <>
        "index: #{counts.index} failures, #{length(coverage.not_provocable)} not provocable; " <>
        "phrases: #{counts.phrases} failures"
    )
  end

  defp fail(message), do: IO.puts("FAIL " <> message)
end

if not List.keymember?(Application.started_applications(), :ex_unit, 0) do
  System.halt(Evals.SkillCheck.run())
end
