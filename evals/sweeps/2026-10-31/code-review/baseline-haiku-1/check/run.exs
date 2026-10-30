alias Accounts.UserImporter, as: U

IO.inspect(U.import_user(%{"email" => "A@X.com", "age" => "150", "role" => "admin"}), label: "cap age")
IO.inspect(U.import_user(%{"email" => "b@x.com", "age" => "17", "role" => "admin"}), label: "minor")
IO.inspect(U.import_user(%{"email" => "c@x.com", "age" => "30", "role" => nil}), label: "nil role")
IO.inspect(U.import_user(%{"email" => nil, "age" => "30", "role" => "admin"}), label: "nil email")
IO.inspect(U.import_user(%{"email" => "d@x.com", "age" => "abc", "role" => "admin"}, return_id: true), label: "bad age")
IO.inspect(U.import_user(%{"email" => "e@x.com", "age" => 30, "role" => "zzz_no_such_role"}), label: "unknown role")
