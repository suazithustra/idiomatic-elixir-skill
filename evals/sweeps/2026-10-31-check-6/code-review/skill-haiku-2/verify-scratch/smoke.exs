Code.require_file("stubs.exs")
Code.require_file("importer.ex")

alias Accounts.UserImporter

{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

ok = %{"email" => "A@Example.com", "age" => "150", "role" => "admin"}
IO.inspect(UserImporter.import_user(ok), label: "clamped age")

IO.inspect(UserImporter.import_user(%{"email" => "b@x.io", "age" => "17", "role" => "admin"}), label: "under 18")
IO.inspect(UserImporter.import_user(%{"email" => "c@x.io", "age" => "30", "role" => "root"}), label: "bad role")
IO.inspect(UserImporter.import_user(%{"age" => "30", "role" => "admin"}), label: "missing email")
IO.inspect(UserImporter.import_user(%{"email" => "d@x.io", "age" => "abc", "role" => "admin"}), label: "bad age")

IO.inspect(UserImporter.import_user(ok, notify: :welcome), label: "welcome path")
Process.sleep(100)

IO.inspect(UserImporter.import_user(ok, notify: :welcome, silent: true), label: "unknown option")
