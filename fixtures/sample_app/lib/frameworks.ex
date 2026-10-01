# Fathom reads framework facts through the reflection functions Ecto and
# Phoenix generate, never by importing either library. These modules implement
# those contracts by hand so the framework passes are covered without the
# fixture depending on a database or a web server.

defmodule SampleApp.Schemas.Account do
  @moduledoc "Stands in for an Ecto schema backed by a real table."

  def __schema__(:source), do: "accounts"
  def __schema__(:fields), do: [:id, :email, :inserted_at]
  def __schema__(:primary_key), do: [:id]
  def __schema__(:associations), do: [:posts]

  def __schema__(:type, :id), do: :id
  def __schema__(:type, :email), do: :string
  def __schema__(:type, :inserted_at), do: :naive_datetime

  def __schema__(:association, :posts) do
    %{cardinality: :many, related: SampleApp.Schemas.Post, field: :posts}
  end
end

defmodule SampleApp.Schemas.Post do
  @moduledoc "The other end of the association."

  def __schema__(:source), do: "posts"
  def __schema__(:fields), do: [:id, :title]
  def __schema__(:primary_key), do: [:id]
  def __schema__(:associations), do: []
  def __schema__(:type, :id), do: :id
  def __schema__(:type, :title), do: :string
end

defmodule SampleApp.Schemas.Address do
  @moduledoc "An embedded schema, which has no table behind it."

  def __schema__(:source), do: nil
  def __schema__(:fields), do: [:line1, :city]
  def __schema__(:primary_key), do: []
  def __schema__(:associations), do: []
  def __schema__(:type, :line1), do: :string
  def __schema__(:type, :city), do: :string
end

defmodule SampleApp.Router do
  @moduledoc "Stands in for a Phoenix router."

  def __routes__ do
    [
      %{
        verb: :get,
        path: "/accounts",
        plug: SampleApp.AccountController,
        plug_opts: :index,
        helper: "account"
      },
      %{
        verb: :delete,
        path: "/accounts/:id",
        plug: SampleApp.AccountController,
        plug_opts: :delete,
        helper: "account"
      }
    ]
  end
end

defmodule SampleApp.AccountController do
  @moduledoc "The endpoint the router points at, so routes join onto the call graph."

  alias SampleApp.Accounts

  def index(conn, _params), do: conn

  def delete(conn, _params) do
    Accounts.purge_users()
    conn
  end
end
