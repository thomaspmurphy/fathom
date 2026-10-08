defmodule SampleApp.Repo do
  @moduledoc "Stands in for an Ecto repo at the bottom of the call graph."

  @doc "Deletes everything matching the query."
  @spec delete_all(term()) :: {integer(), nil}
  def delete_all(_query), do: {0, nil}

  def insert(record), do: {:ok, record}
end

defprotocol SampleApp.Describable do
  @doc "Renders a term for a human."
  def describe(term)
end

defmodule SampleApp.User do
  @moduledoc "A struct used from other modules, so struct_expansion fires."
  defstruct [:id, :name, :email]
end

defimpl SampleApp.Describable, for: SampleApp.User do
  def describe(%SampleApp.User{name: name}), do: "user #{name}"
end

defmodule SampleApp.Behaviour do
  @callback handle(term()) :: :ok | {:error, term()}
end

defmodule SampleApp.Injector do
  @moduledoc """
  Injects functions the way a framework's `use` does, so the generated flag
  has something to detect that no line-collision heuristic could.

  `injected_solo/0` is deliberately the only definition its macro produces:
  it is generated, but it shares its line with nothing.
  """

  defmacro __using__(_opts) do
    quote do
      def injected_one, do: :one
      def injected_two, do: :two
      defp injected_private, do: :private
      def injected_caller, do: injected_private()
    end
  end

  defmacro inject_solo do
    quote do
      def injected_solo, do: :solo
    end
  end
end

defmodule SampleApp.Injected do
  @moduledoc "Mixes generated and hand-written definitions in one module."

  require SampleApp.Injector
  use SampleApp.Injector

  SampleApp.Injector.inject_solo()

  @doc "Written by hand, with defaults that expand to three arities on one line."
  def written_with_defaults(a, b \\ :b, c \\ :c), do: {a, b, c}

  def written_plain, do: :plain
end

defmodule SampleApp.Accounts do
  @moduledoc "The context module. Sits between the web layer and the repo."

  @behaviour SampleApp.Behaviour

  alias SampleApp.{Repo, User}

  @type result :: {:ok, %User{}} | {:error, term()}

  @impl true
  def handle(_term), do: :ok

  @doc "Creates a user from the given attributes."
  @spec create_user(map()) :: result()
  def create_user(attrs) do
    attrs
    |> build_user()
    |> Repo.insert()
  end

  @doc "Removes every user. Reaches `Repo.delete_all/1` transitively."
  def purge_users do
    delete_users()
  end

  defp delete_users, do: Repo.delete_all(User)

  defp build_user(attrs), do: struct(%User{}, attrs)
end

defmodule SampleApp.Dispatcher do
  @moduledoc "Every form of dispatch the static call graph cannot follow."

  def via_apply(module, args), do: apply(module, :handle, args)

  def via_variable(module, arg), do: module.handle(arg)

  def via_config(arg) do
    handler = Application.get_env(:sample_app, :handler)
    handler.handle(arg)
  end

  def static_field_access(map), do: map.name
end

defmodule SampleApp.Web do
  @moduledoc "Top of the graph, so a recursive query has somewhere to start."

  alias SampleApp.Accounts

  def delete_account_action(_conn) do
    Accounts.purge_users()
  end

  defmacro render_inline(template) do
    quote do: unquote(template)
  end
end
