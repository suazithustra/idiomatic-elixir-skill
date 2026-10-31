locals_without_parens = [get: 2]

[
  inputs: ["*.ex", "*.exs"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
