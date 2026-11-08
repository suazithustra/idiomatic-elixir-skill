ExUnit.start()

defmodule Evals.CheckScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../idiomatic-elixir/scripts/check.exs", __DIR__)

  # The script runs its main function when loaded and halts with status 1 on findings, so
  # each test runs it as an agent or a hook would, in its own process.
  defp check(files) do
    dir = tmp_dir()
    paths = Enum.map(files, fn {name, source} -> write!(dir, name, source) end)
    {output, status} = System.cmd("elixir", [@script | paths], stderr_to_stdout: true)
    {String.replace(output, dir <> "/", ""), status}
  end

  defp hook(payload) do
    dir = tmp_dir()
    input = write!(dir, "payload.json", payload)
    {output, 0} = System.cmd("sh", ["-c", ~s(elixir "#{@script}" < "#{input}")])
    output
  end

  defp context(output) do
    output
    |> JSON.decode!()
    |> get_in(["hookSpecificOutput", "additionalContext"])
  end

  # Unique integers restart with each VM, so a folder a previous run left behind would be
  # read together with this one's files.
  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "check-script-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(dir, name, source) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  defp module(body), do: "defmodule Sample do\n#{body}\nend\n"

  describe "a one-line if with an else" do
    test "is reported past about 60 characters" do
      source =
        module("""
          def bound(flow, binding, carrier) do
            if Plug.Crypto.secure_compare(flow, binding), do: {:ok, carrier}, else: {:error, :mismatch}
          end
        """)

      assert {output, 1} = check(%{"a.ex" => source})
      assert output =~ "a.ex:3: a one-line `if ..., do: ..., else: ...` of 95 characters"
    end

    test "is reported when the formatter has wrapped it onto several lines" do
      source =
        module("""
          def canonical(token, bytes) do
            if Base.url_encode64(bytes, padding: false) == token,
              do: {:ok, :crypto.hash(:sha256, bytes)},
              else: :error
          end
        """)

      assert {output, 1} = check(%{"a.ex" => source})
      assert output =~ "a.ex:3: a one-line `if"
    end

    test "is accepted when short, and a do ... end block always is" do
      source =
        module("""
          def label(term), do: if(String.valid?(term), do: term, else: "binary")

          def clamp(n) do
            if n < 0 do
              0
            else
              n
            end
          end
        """)

      assert check(%{"a.ex" => source}) == {"", 0}
    end
  end

  describe "== against a value built in place" do
    test "is reported when one side is a call" do
      source = module("  def same?(id, current), do: Ecto.UUID.cast(id) == {:ok, current}")

      assert {output, 1} = check(%{"a.ex" => source})
      assert output =~ "a.ex:2: `==` compares a call's result with a value built in place"
    end

    test "is accepted inside assert and refute, and between plain values" do
      source = """
      defmodule SampleTest do
        use ExUnit.Case

        test "parses" do
          assert Address.parse("a@b") == {:ok, "a@b"}
          refute Address.parse("a") == {:ok, "a"}
        end

        def same?(result, current), do: result == {:ok, current}
      end
      """

      assert check(%{"a_test.exs" => source}) == {"", 0}
    end
  end

  describe "pipelines" do
    test "a step that spans several lines is reported" do
      source =
        module("""
          def summaries(orders) do
            orders
            |> Enum.filter(&completed?/1)
            |> Enum.map(fn order ->
              %{id: order.id, total: order.total}
            end)
          end
        """)

      assert {output, 1} = check(%{"a.ex" => source})
      assert output =~ "a.ex:5: a step after `|>` spans lines 5-7"
    end

    test "a pipeline on one line is reported once however many steps it has" do
      source =
        module("  def words(sql), do: sql |> String.split() |> Enum.uniq() |> Enum.sort()")

      assert {output, 1} = check(%{"a.ex" => source})
      assert [_one] = String.split(output, "\n", trim: true)
      assert output =~ "a.ex:2: a pipeline on one line"
    end

    test "one step per line, and a multi-line case as the head, are accepted" do
      source =
        module("""
          def rows(mode, rows) do
            case mode do
              :all -> rows
              :some -> Enum.take(rows, 3)
            end
            |> Enum.map(&to_string/1)
            |> Enum.sort()
          end
        """)

      assert check(%{"a.ex" => source}) == {"", 0}
    end
  end

  test "files that are not Elixir, or do not parse, are skipped" do
    files = %{"notes.md" => "if x, do: y, else: z", "broken.ex" => "defmodule Broken do"}

    assert check(files) == {"", 0}
  end

  describe "as a hook" do
    test "reads Claude Code's file_path and answers with additionalContext" do
      dir = tmp_dir()
      path = write!(dir, "a.ex", module("  def words(s), do: s |> String.split() |> Enum.uniq()"))
      output = hook(JSON.encode!(%{tool_name: "Edit", tool_input: %{file_path: path}}))

      assert context(output) =~ "- #{path}:2: a pipeline on one line"
    end

    test "reads the files named in a Codex patch, relative to its cwd" do
      dir = tmp_dir()
      write!(dir, "lib/a.ex", module("  def words(s), do: s |> String.split() |> Enum.uniq()"))
      write!(dir, "notes.md", "s |> String.split() |> Enum.uniq()")

      patch = """
      *** Begin Patch
      *** Update File: lib/a.ex
      @@
      -old
      +new
      *** Add File: notes.md
      +text
      *** End Patch
      """

      output =
        hook(JSON.encode!(%{tool_name: "apply_patch", cwd: dir, tool_input: %{command: patch}}))

      assert context(output) =~ "- #{Path.join(dir, "lib/a.ex")}:2: a pipeline on one line"
      refute context(output) =~ "notes.md"
    end

    test "says nothing for a clean file or input it cannot read" do
      dir = tmp_dir()
      path = write!(dir, "a.ex", module("  def id(x), do: x"))

      assert hook(JSON.encode!(%{tool_input: %{file_path: path}})) == ""
      assert hook("not json") == ""
      assert hook(JSON.encode!(%{tool_input: %{command: "ls -la"}})) == ""
    end
  end
end
