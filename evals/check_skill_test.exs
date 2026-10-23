ExUnit.start()

Code.require_file("check_skill.exs", __DIR__)

defmodule Evals.SkillCheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Evals.SkillCheck

  defp block(heading, code, file \\ "SKILL.md") do
    %{file: file, heading: heading, ordinal: 1, code: code}
  end

  defp write_tree(files) do
    root = Path.join(System.tmp_dir!(), "skill-check-#{System.unique_integer([:positive])}")

    for {path, content} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    root
  end

  @clean_tree %{
    "idiomatic-elixir/SKILL.md" => "# Skill\n\n### Rule one\n\n```elixir\na = 1\n```\n",
    "idiomatic-elixir/references/ex_unit.md" => "# Tests\n\n## Assert with patterns\n",
    "evals/README.md" => """
    | File | Phrase |
    | --- | --- |
    | `ex_unit.md` | `Assert with patterns` |

    | Rule | Cases | Without skill |
    | --- | --- | --- |
    | Rule one | webhook-parser | |
    | Assert with patterns | test-writing | |
    """
  }

  describe "extract_blocks/2" do
    test "returns each elixir block with its file, heading, and ordinal" do
      markdown = """
      ### First rule

      ```elixir
      a = 1
      ```

      Prose between.

      ```elixir
      b = 2
      ```

      ### Second rule

      ```elixir
      @doc \"\"\"
      Imports a user.

      ## Options

        * `:notify` - sends an email.
      \"\"\"
      def import_user(params), do: params
      ```
      """

      assert [
               %{file: "SKILL.md", heading: "First rule", ordinal: 1, code: "a = 1\n"},
               %{file: "SKILL.md", heading: "First rule", ordinal: 2, code: "b = 2\n"},
               %{file: "SKILL.md", heading: "Second rule", ordinal: 1, code: second}
             ] = SkillCheck.extract_blocks(markdown, "SKILL.md")

      assert second =~ "## Options"
    end

    test "turns an unclosed fence into a block that fails the parse tier" do
      markdown = "### Rule\n\n```elixir\na = 1\n"

      assert [%{heading: "Rule", unclosed: "elixir"} = block] =
               SkillCheck.extract_blocks(markdown, "SKILL.md")

      assert {:failed, [%{tier: :parse, reason: reason}]} = SkillCheck.check_block(block)
      assert reason =~ "never closed"
    end
  end

  describe "rule_headings/2" do
    test "takes the level-three rules plus Naming and Before you finish, skipping fenced lines" do
      markdown = """
      ## How to use this skill

      ### Real rule

      ```elixir
      @doc \"\"\"
      ### Options
      \"\"\"
      ```

      ## Naming

      ## Before you finish
      """

      assert SkillCheck.rule_headings(markdown, "SKILL.md") ==
               ["Real rule", "Naming", "Before you finish"]
    end

    test "takes every level-two heading of a reference file except the list heading" do
      markdown = """
      # ExUnit tests

      ## Assert with patterns

      ## Other ExUnit features to reach for
      """

      assert SkillCheck.rule_headings(markdown, "references/ex_unit.md") == [
               "Assert with patterns"
             ]
    end
  end

  describe "check_block/1" do
    test "fails the parse tier on an unbalanced do and names the heading" do
      assert {:failed, [%{tier: :parse, heading: "Broken"}]} =
               SkillCheck.check_block(block("Broken", "if x do\n  1\n"))
    end

    test "passes a marker block whose parts are formatted even though the whole block is not" do
      code = "# Instead of\nif a do\n  foo(1)\nend\n# write\nfoo(2)\n"
      formatted_whole = code |> Code.format_string!() |> IO.iodata_to_binary()

      refute formatted_whole == String.trim_trailing(code)
      assert :ok = SkillCheck.check_block(block("Marker", code))
    end

    test "accepts a blank line between a marker comment and its code" do
      code = "# Instead of\nx = foo(1)\n# write\n\ny = foo(2)\n"
      assert :ok = SkillCheck.check_block(block("Marker", code))
    end

    test "names the part when one part is not formatted" do
      code = "# Instead of\nx = foo( 1)\n# write\ny = foo(2)\n"

      assert {:failed, [%{tier: :format, part: "Instead of"}]} =
               SkillCheck.check_block(block("Marker", code))
    end

    test "names the or part when the third snippet is not formatted" do
      code = "# Instead of\nx = foo(1)\n# write\ny = foo(2)\n# or\nz = foo( 3)\n"

      assert {:failed, [%{tier: :format, part: "or"}]} =
               SkillCheck.check_block(block("Marker", code))
    end

    test "compiles only the part that defines a module and purges it afterwards" do
      code = """
      # Instead of
      Agent.update(bucket, fn state -> Map.put(state, "milk", 3) end)
      # write
      defmodule Evals.SkillCheckTest.Probe do
        def hello, do: :world
      end
      """

      assert :ok = SkillCheck.check_block(block("Bucket", code))
      refute Code.ensure_loaded?(Evals.SkillCheckTest.Probe)
    end

    test "fails a module part that produces a diagnostic" do
      code = "defmodule Evals.SkillCheckTest.Broken do\n  def go, do: missing()\nend\n"

      assert {:failed, [%{tier: :compile, reason: reason}]} =
               SkillCheck.check_block(block("Module", code))

      assert reason =~ "missing"
    end

    test "fails a module part that compiles with a warning" do
      code =
        "defmodule Evals.SkillCheckTest.Warned do\n  def go do\n    unused = 1\n    :ok\n  end\nend\n"

      assert {:failed, [%{tier: :compile, reason: reason}]} =
               SkillCheck.check_block(block("Module", code))

      assert reason =~ "unused"
      refute Code.ensure_loaded?(Evals.SkillCheckTest.Warned)
    end

    test "compiles a protocol implementation and fails it on a diagnostic" do
      code = """
      defimpl String.Chars, for: Evals.SkillCheckTest.Thing do
        def to_string(_thing), do: missing()
      end
      """

      assert {:failed, [%{tier: :compile, reason: reason}]} =
               SkillCheck.check_block(block("Impl", code))

      assert reason =~ "missing"
    end

    test "purges a module that loaded before a later module in the same part failed" do
      code = """
      defmodule Evals.SkillCheckTest.Keep do
        def a, do: 1
      end

      defmodule Evals.SkillCheckTest.Bad do
        def b, do: missing()
      end
      """

      assert {:failed, [%{tier: :compile}]} = SkillCheck.check_block(block("Two", code))
      refute Code.ensure_loaded?(Evals.SkillCheckTest.Keep)
    end

    test "reports a listed fragment as skipped" do
      heading = "Use `and`, `or`, `not` when the operands are booleans"
      code = "# Instead of\nif a && b do\n# write\nif a and b do\n"
      assert :skipped = SkillCheck.check_block(block(heading, code))
    end
  end

  describe "index_rows/1" do
    test "reads the coverage table and unescapes pipes in the rule cell" do
      readme = """
      ## Which case exercises which rule

      | Rule | Cases | Without skill |
      | --- | --- | --- |
      | Update structs with `%{struct \\| field: value}` | shop-project | |
      | Treat lists as linked lists | order-report | |
      """

      assert [
               %{rule: "Update structs with `%{struct | field: value}`", cases: "shop-project"},
               %{rule: "Treat lists as linked lists", cases: "order-report"}
             ] = SkillCheck.index_rows(readme)
    end
  end

  describe "coverage/2" do
    test "reports a heading with no row, an orphan row, a none yet row, and a not provocable row" do
      headings = [
        "Covered rule",
        "Uncovered rule",
        "Unprovoked rule",
        "Pending rule",
        "Annotated rule",
        "Blank rule",
        "Bare rule"
      ]

      rows = [
        %{rule: "Covered rule", cases: "webhook-parser"},
        %{rule: "Unprovoked rule", cases: "not provocable: no prompt builds a 32-field struct"},
        %{rule: "Pending rule", cases: "none yet"},
        %{rule: "Annotated rule", cases: "none yet: waiting on a prompt"},
        %{rule: "Blank rule", cases: ""},
        %{rule: "Bare rule", cases: "not provocable"},
        %{rule: "Renamed rule", cases: "order-report"}
      ]

      assert %{
               missing: ["Uncovered rule"],
               orphans: ["Renamed rule"],
               none_yet: ["Pending rule", "Annotated rule", "Blank rule"],
               unexplained: ["Bare rule"],
               not_provocable: ["Unprovoked rule"]
             } = SkillCheck.coverage(headings, rows)
    end
  end

  describe "run/1" do
    test "exits 0 on a clean tree and 1 for a broken block, an orphan row, or a duplicated phrase" do
      clean = write_tree(@clean_tree)
      assert {0, _output} = with_io(fn -> SkillCheck.run(clean) end)

      broken_block =
        Map.put(
          @clean_tree,
          "idiomatic-elixir/SKILL.md",
          "### Rule one\n\n```elixir\na = (\n```\n"
        )

      assert {1, output} = with_io(fn -> SkillCheck.run(write_tree(broken_block)) end)
      assert output =~ "FAIL SKILL.md | Rule one | parse"

      orphan_row =
        Map.update!(@clean_tree, "evals/README.md", &(&1 <> "| Rule two | order-report | |\n"))

      assert {1, output} = with_io(fn -> SkillCheck.run(write_tree(orphan_row)) end)
      assert output =~ "names no rule heading"

      duplicated =
        Map.update!(@clean_tree, "idiomatic-elixir/SKILL.md", &(&1 <> "\nAssert with patterns\n"))

      assert {1, output} = with_io(fn -> SkillCheck.run(write_tree(duplicated)) end)
      assert output =~ "phrase"
    end
  end

  describe "phrase_findings/2" do
    test "fails a phrase that occurs twice, never, or in the wrong file, and passes one that occurs once in its file" do
      rows = [
        %{file: "references/a.md", phrase: "Only here"},
        %{file: "references/b.md", phrase: "Twice"},
        %{file: "references/b.md", phrase: "Nowhere"},
        %{file: "references/b.md", phrase: "Elsewhere"}
      ]

      contents = %{
        "SKILL.md" => "Twice\nElsewhere\n",
        "references/a.md" => "## Only here\n",
        "references/b.md" => "## Twice\n"
      }

      assert [
               %{phrase: "Twice"},
               %{phrase: "Nowhere"},
               %{phrase: "Elsewhere", in_file: 0, total: 1}
             ] = SkillCheck.phrase_findings(rows, contents)
    end
  end
end
