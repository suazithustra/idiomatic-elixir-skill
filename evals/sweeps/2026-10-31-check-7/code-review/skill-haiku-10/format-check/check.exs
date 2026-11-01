dir = Path.dirname(__ENV__.file)

for name <- ["user_importer.ex", "user.ex"] do
  src = File.read!(Path.join(dir, name))
  formatted = IO.iodata_to_binary([Code.format_string!(src), "\n"])
  IO.puts("#{name}: #{if formatted == src, do: "formatted", else: "NOT formatted"}")
end
