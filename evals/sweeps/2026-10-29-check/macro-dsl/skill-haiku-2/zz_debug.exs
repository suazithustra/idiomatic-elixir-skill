Code.require_file("tiny_router.ex", __DIR__)

IO.inspect(TinyRouter.__match__("/users/42", [{[{:static, "users"}, {:param, "id"}], MyApp.UserHandler}]), label: "direct")
IO.inspect(MyApp.Router.__info__(:functions), label: "functions")
IO.inspect(:erlang.function_exported(MyApp.Router, :match, 1), label: "exported")
