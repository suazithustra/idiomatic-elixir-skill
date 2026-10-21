{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

IO.inspect(Accounts.UserImporter.import_user(%{"email" => "A@X.com", "age" => "150", "role" => "admin"}), label: "clamp")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "b@x.com", "age" => "abc", "role" => "admin"}), label: "bad age")
IO.inspect(Accounts.UserImporter.import_user(%{"age" => "30", "role" => "admin"}), label: "no email")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "c@x.com", "age" => "20", "role" => "root"}), label: "bad role")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "c@x.com", "age" => "12", "role" => "viewer"}), label: "under 18")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "d@x.com", "age" => "20", "role" => "viewer"}, welcome_email: :send), label: "welcome")
IO.inspect(Accounts.UserImporter.import_user_id(%{"email" => "e@x.com", "age" => "20", "role" => "viewer"}), label: "id")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "f@x.com", "age" => "20", "role" => "viewer"}, notify: true), label: "old option")

Process.sleep(100)
