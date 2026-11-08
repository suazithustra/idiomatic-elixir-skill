# Reports the shapes the skill's rules forbid but long sessions keep writing. An agent runs
# it on the files it changed, `elixir check.exs lib/a.ex lib/b.ex`; a PostToolUse hook in
# Claude Code or Codex runs it with no arguments and the edit as JSON on stdin, so the
# finding reaches the agent while the line is new however long the session has run.
defmodule IdiomaticElixir.Check do
  @max_inline_if 60

  def main([]) do
    with {:ok, input} <- read_input() do
      input
      |> edited_paths()
      |> elixir_findings()
      |> report_to_hook()
    end
  end

  def main(paths) do
    case elixir_findings(paths) do
      [] ->
        :ok

      found ->
        Enum.each(found, &IO.puts(format_finding(&1)))
        System.halt(1)
    end
  end

  defp elixir_findings(paths) do
    paths
    |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
    |> Enum.flat_map(&file_findings/1)
  end

  # Claude Code's Edit and Write name one file. Codex's apply_patch sends the patch text,
  # whose header lines name each file it adds, updates or moves, relative to the session's
  # working directory.
  defp edited_paths(%{"tool_input" => %{"file_path" => path}}) when is_binary(path), do: [path]

  defp edited_paths(%{"tool_input" => %{"command" => patch}} = input) when is_binary(patch) do
    cwd = Map.get(input, "cwd") || File.cwd!()

    ~r/^\*\*\* (?:Add File|Update File|Move to): (.+)$/m
    |> Regex.scan(patch, capture: :all_but_first)
    |> Enum.map(fn [path] -> Path.expand(String.trim(path), cwd) end)
    |> Enum.uniq()
  end

  defp edited_paths(_input), do: []

  defp file_findings(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source, token_metadata: true, columns: true) do
      Enum.map(findings(ast), fn {line, message} -> {path, line, message} end)
    else
      _unreadable -> []
    end
  end

  defp read_input do
    case JSON.decode(IO.read(:stdio, :eof)) do
      {:ok, input} when is_map(input) -> {:ok, input}
      _other -> :error
    end
  end

  defp findings(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn node, found -> {exempt_assertion(node), check(node) ++ found} end)

    found
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ExUnit's `assert left == right` is how the skill's own ExUnit reference compares a
  # result, and it prints a diff on failure, so the comparison is renamed before the walk
  # reaches it; the operands are still walked.
  defp exempt_assertion({assertion, meta, [{:==, eq_meta, operands}]})
       when assertion in [:assert, :refute] do
    {assertion, meta, [{:__asserted_equal__, eq_meta, operands}]}
  end

  defp exempt_assertion(node), do: node

  defp check({:if, meta, [_condition, [{_do, _then}, {_else, _otherwise}]]} = node) do
    text = Macro.to_string(node)

    if Keyword.has_key?(meta, :do) or String.length(text) <= @max_inline_if do
      []
    else
      [
        {meta[:line],
         "a one-line `if ..., do: ..., else: ...` of #{String.length(text)} characters; " <>
           "an `if` with an `else` takes `do ... end` past about #{@max_inline_if}"}
      ]
    end
  end

  defp check({:==, meta, [left, right]}) do
    if (built?(left) and call?(right)) or (built?(right) and call?(left)) do
      [
        {meta[:line],
         "`==` compares a call's result with a value built in place; " <>
           "match it in a `case` and pin the value you expect"}
      ]
    else
      []
    end
  end

  defp check({:|>, meta, [left, right]}) do
    one_line_pipeline(meta, left) ++ multi_line_step(meta, right)
  end

  defp check(_node), do: []

  defp built?({_left, _right}), do: true
  defp built?({:{}, _meta, _elements}), do: true
  defp built?({:%{}, _meta, _pairs}), do: true
  defp built?(_other), do: false

  defp call?({{:., _meta, _target}, _call_meta, _args}), do: true

  defp call?({name, _meta, args}) when is_atom(name) and is_list(args),
    do: not Macro.operator?(name, length(args))

  defp call?(_other), do: false

  # Only the pipe whose left side is itself a pipe on the same line reports, so a chain
  # written on one line gives one finding however many steps it has.
  defp one_line_pipeline(meta, {:|>, inner_meta, _args}) do
    if meta[:line] == inner_meta[:line] do
      [
        {meta[:line],
         "a pipeline on one line; put each `|>` step on its own line under the value"}
      ]
    else
      []
    end
  end

  defp one_line_pipeline(_meta, _left), do: []

  defp multi_line_step(meta, step) do
    {first, last} = line_span(step)

    if last > first do
      [
        {meta[:line],
         "a step after `|>` spans lines #{first}-#{last}; " <>
           "move it into a named private function so the step fits on its line"}
      ]
    else
      []
    end
  end

  # The step's own lines, including where its `fn` or call closes, so a step whose body
  # sits below its head counts as spanning lines.
  defp line_span(node) do
    {_node, lines} =
      Macro.prewalk(node, [], fn
        {_name, meta, _args} = inner, lines when is_list(meta) ->
          {inner, closing_lines(meta) ++ lines}

        inner, lines ->
          {inner, lines}
      end)

    Enum.min_max(lines, fn -> {0, 0} end)
  end

  defp closing_lines(meta) do
    [meta[:line], get_in(meta, [:closing, :line]), get_in(meta, [:end, :line])]
    |> Enum.reject(&is_nil/1)
  end

  defp format_finding({path, line, message}), do: "#{path}:#{line}: #{message}"

  defp report_to_hook([]), do: :ok

  defp report_to_hook(found) do
    lines = Enum.map_join(found, "\n", &("- " <> format_finding(&1)))
    context = "idiomatic-elixir check on the file just edited:\n" <> lines

    IO.puts(
      JSON.encode!(%{
        hookSpecificOutput: %{hookEventName: "PostToolUse", additionalContext: context}
      })
    )
  end
end

IdiomaticElixir.Check.main(System.argv())
