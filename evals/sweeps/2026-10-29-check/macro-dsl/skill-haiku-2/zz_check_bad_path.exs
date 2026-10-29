Code.require_file("tiny_router.ex", __DIR__)

defmodule Bad do
  use TinyRouter
  get :users, MyApp.UserHandler
end
