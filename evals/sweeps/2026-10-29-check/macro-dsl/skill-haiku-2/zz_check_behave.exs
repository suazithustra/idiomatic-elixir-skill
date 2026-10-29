Code.require_file("tiny_router.ex", __DIR__)

IO.inspect(MyApp.Router.routes(), label: "routes")
IO.inspect(MyApp.Router.match("/"), label: "/")
IO.inspect(MyApp.Router.match("/users/42"), label: "/users/42")
IO.inspect(MyApp.Router.match("/users"), label: "/users")
IO.inspect(MyApp.Router.match("/users/42/extra"), label: "extra")
IO.inspect(MyApp.Router.match("/nope"), label: "/nope")
