# Deliberately minimal: no explicit `enabled:` list.
#
# Credo treats an `enabled:` list as authoritative and discards whatever a
# plugin registers, so `mix credo.gen.config` would silently turn ExSlop into a
# no-op. Leaving the list out keeps Credo's defaults and lets the plugin
# contribute its recommended checks.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # The sample app is written to exercise the tracer, not to be good
        # Elixir: it dispatches through variables and config on purpose.
        excluded: [~r"/_build/", ~r"/deps/", ~r"/fixtures/"]
      },
      strict: true,
      plugins: [{ExSlop, []}],
      checks: %{
        extra: [],
        disabled: []
      }
    }
  ]
}
