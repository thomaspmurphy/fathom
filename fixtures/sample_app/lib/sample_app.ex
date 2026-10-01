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
