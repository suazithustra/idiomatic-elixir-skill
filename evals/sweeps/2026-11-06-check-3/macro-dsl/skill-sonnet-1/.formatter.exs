locals_without_parens = [get: 2]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "tiny_router.ex"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
