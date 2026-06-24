[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "docs/**/*.{md,markdown}"
  ],
  line_length: 98,
  subdirectories: ["priv/*/migrations/*.{ex,exs}"]
]
