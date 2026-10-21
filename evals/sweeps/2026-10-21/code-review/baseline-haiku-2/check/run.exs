Process.register(self(), :test_proc)
{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

check = fn label, got, want ->
  IO.puts("#{if got == want, do: "PASS", else: "FAIL"} #{label}: got #{inspect(got)}")
end

alias Accounts.UserImporter, as: UI

base = %{"email" => "A@X.com", "age" => "30", "role" => "admin"}
with_field = fn k, v -> Map.put(base, k, v) end

{:ok, u1} = UI.import_user(base)
check.("email downcased", u1.email, "a@x.com")
{:ok, u2} = UI.import_user(with_field.("age", "130"))
check.("age string 130 capped", u2.age, 120)
{:ok, u3} = UI.import_user(with_field.("age", 130))
check.("age integer 130 capped", u3.age, 120)
{:ok, u4} = UI.import_user(with_field.("age", 30))
check.("age integer 30 accepted", u4.age, 30)
check.("age 17 rejected", UI.import_user(with_field.("age", "17")), {:error, :invalid})
check.("age abc rejected", UI.import_user(with_field.("age", "abc")), {:error, :invalid})
check.("unknown role rejected", UI.import_user(with_field.("role", "root")), {:error, :invalid})
check.("nil role rejected", UI.import_user(Map.delete(base, "role")), {:error, :invalid})
check.("nil email rejected", UI.import_user(Map.delete(base, "email")), {:error, :invalid})
check.("return_id", UI.import_user(with_field.("email", "b@x.com"), return_id: true), 42)
check.("insert failure", UI.import_user(with_field.("email", "fail@x.com")), {:error, :insert_failed})

UI.import_user(with_field.("email", "c@x.com"), notify: true)

receive do
  {:mail, msg} -> check.("welcome mail sent", String.contains?(msg, "welcome"), true)
after
  500 -> check.("welcome mail sent", :timeout, :mail)
end
