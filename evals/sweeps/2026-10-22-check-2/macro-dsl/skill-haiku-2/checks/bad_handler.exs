Code.require_file("../tiny_router.ex", __DIR__)

defmodule Bad2 do
  use TinyRouter

  handler = MyApp.PageHandler
  get "/", handler
end
