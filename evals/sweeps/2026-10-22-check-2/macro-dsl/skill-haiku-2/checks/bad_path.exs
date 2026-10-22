Code.require_file("../tiny_router.ex", __DIR__)

defmodule Bad1 do
  use TinyRouter

  get :home, MyApp.PageHandler
end
