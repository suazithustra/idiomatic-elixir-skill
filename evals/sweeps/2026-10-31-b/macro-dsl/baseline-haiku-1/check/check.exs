Code.require_file("/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/sweep-2026-10-31-b-root/runs/macro-dsl/baseline-haiku-1/tiny_router.ex")

IO.inspect(MyApp.Router.routes(), label: "routes")
IO.inspect(MyApp.Router.match("/"), label: "/")
IO.inspect(MyApp.Router.match("/users/42"), label: "/users/42")
IO.inspect(MyApp.Router.match("/nope"), label: "/nope")
IO.inspect(MyApp.Router.match("/users/42/x"), label: "/users/42/x")

bad_bodies = [
  ~s|get "/x/:id", 123|,
  ~s|get :oops, MyApp.X|,
  ~s|get "/x/:Id", MyApp.X|,
  ~s|get "/x/:a/:a", MyApp.X|,
  ~s|get "/x", "string"|
]

for body <- bad_bodies do
  source = "defmodule Bad#{System.unique_integer([:positive])} do\n  use TinyRouter\n  #{body}\nend\n"

  try do
    Code.eval_string(source, [], file: "bad.exs")
    IO.puts("NO ERROR: #{body}")
  rescue
    e -> IO.puts("#{body}\n  -> #{Exception.message(e)}")
  end
end
