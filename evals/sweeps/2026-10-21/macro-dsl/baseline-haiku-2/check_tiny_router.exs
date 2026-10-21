src = "/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/sweep/runs/macro-dsl/baseline-haiku-2/tiny_router.ex"
Code.require_file(src)

IO.inspect(MyApp.Router.routes(), label: "routes")
IO.inspect(MyApp.Router.match("/"), label: "match /")
IO.inspect(MyApp.Router.match("/users/42"), label: "match /users/42")
IO.inspect(MyApp.Router.match("/users/42/extra"), label: "match extra")
IO.inspect(MyApp.Router.match("/nope"), label: "match nope")
IO.inspect(MyApp.Router.match(:x), label: "match non-binary")

cases = [
  ~s|get 123, MyApp.X|,
  ~s|get "/a", "not_a_module"|,
  ~s|get "/a", :lower|,
  ~s|get "/:id/:id", MyApp.X|
]

for body <- cases do
  dir = "/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/sweep/runs/macro-dsl/baseline-haiku-2"
  File.write!(Path.join(dir, "bad.exs"), "defmodule Bad do\n  use TinyRouter\n  #{body}\nend\n")

  try do
    Code.require_file(Path.join(dir, "bad.exs"))
    IO.puts("NO ERROR for: #{body}")
  rescue
    e in CompileError -> IO.puts("#{body}\n  -> #{Exception.message(e)}")
  end
end
