Code.compile_file("stubs.exs")
Code.compile_file("improved.ex")
{:ok, _pid} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

IO.inspect(Accounts.UserImporter.import_user(%{"email" => "A@X.com", "age" => "150", "role" => "admin"}), label: "ok case")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "A@X.com", "age" => "12", "role" => "admin"}), label: "too young")
IO.inspect(Accounts.UserImporter.import_user(%{"age" => "30", "role" => "admin"}), label: "missing email")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "a@x.com", "age" => "30", "role" => "root"}), label: "bad role")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "a@x.com", "age" => "30", "role" => "admin"}, notify: true), label: "notify")
