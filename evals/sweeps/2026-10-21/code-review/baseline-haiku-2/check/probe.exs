Process.register(self(), :test_proc)

base = %{"email" => "A@X.com", "age" => "130", "role" => "admin"}

IO.inspect(Accounts.UserImporter.import_user(base), label: "age 130 string")
IO.inspect(Accounts.UserImporter.import_user(Map.put(base, "age", 130)), label: "age 130 integer")
IO.inspect(Accounts.UserImporter.import_user(Map.put(base, "age", 30)), label: "age 30 integer")

Accounts.UserImporter.import_user(Map.put(base, "email", "c@x.com") |> Map.put("age", "30"), notify: true)

receive do
  {:mail, msg} -> IO.inspect(msg, label: "mail sent")
after
  500 -> IO.puts("no mail sent (welcome email never delivered)")
end

try do
  Accounts.User.__struct__() |> Access.fetch(:name) |> IO.inspect(label: "Access on struct")
rescue
  e -> IO.puts("Access on struct raises: " <> Exception.message(e) |> String.slice(0, 120))
end
