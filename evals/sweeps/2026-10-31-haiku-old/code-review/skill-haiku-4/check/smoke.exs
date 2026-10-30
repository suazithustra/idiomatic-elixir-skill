{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

alias Accounts.UserImporter

IO.inspect(UserImporter.import_user(%{"email" => "A@X.com", "age" => "150", "role" => "admin"}), label: "capped")
IO.inspect(UserImporter.import_user(%{"email" => "a@x.com", "age" => "12"}), label: "under 18")
IO.inspect(UserImporter.import_user(%{"age" => "20"}), label: "no email")
IO.inspect(UserImporter.import_user(%{"email" => "a@x.com", "age" => "abc"}), label: "bad age")
IO.inspect(UserImporter.import_user(%{"email" => "a@x.com", "age" => "30"}, notify: true), label: "notify")
Process.sleep(100)
