Code.require_file(
  "/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/haiku-old-root/runs/macro-dsl/skill-haiku-2/tiny_router.ex"
)

IO.inspect(MyApp.Router.routes(), label: "routes")
IO.inspect(MyApp.Router.match("/"), label: "match /")
IO.inspect(MyApp.Router.match("/users/42"), label: "match /users/42")
IO.inspect(MyApp.Router.match("/users/42/extra"), label: "match extra")
IO.inspect(MyApp.Router.match("/nope"), label: "match /nope")

bad_path = """
defmodule Bad1 do
  use TinyRouter
  get :home, MyApp.PageHandler
end
"""

bad_handler = """
defmodule Bad2 do
  use TinyRouter
  get "/", :not_a_module
end
"""

for {label, code} <- [{"non-string path", bad_path}, {"atom handler", bad_handler}] do
  try do
    Code.eval_string(code)
    IO.puts("#{label}: NO ERROR")
  rescue
    e -> IO.puts("#{label}: #{Exception.message(e)}")
  end
end
