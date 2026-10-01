defmodule Fathom.ApiTest do
  @moduledoc "The Elixir-side reading API, which exists so linters can be built on the database."

  use ExUnit.Case, async: false

  import Fathom.Fixture

  setup_all do
    build!()
    :ok
  end

  test "query/3 returns columns alongside rows" do
    assert {:ok, ["mfa", "kind"], [["SampleApp.Accounts.create_user/1", "def"]]} =
             Fathom.query(
               "SELECT mfa, kind FROM functions WHERE mfa = ?",
               ["SampleApp.Accounts.create_user/1"],
               db_path()
             )
  end

  test "query!/3 returns rows as maps" do
    assert [%{"name" => "purge_users", "arity" => 0}] =
             Fathom.query!(
               "SELECT name, arity FROM functions WHERE mfa = ?",
               ["SampleApp.Accounts.purge_users/0"],
               db_path()
             )
  end

  test "forbid/3 passes when a rule finds no violations" do
    assert :ok =
             Fathom.forbid(
               "SELECT caller FROM calls WHERE callee_module = 'NoSuchModule'",
               [],
               db_path()
             )
  end

  test "forbid/3 returns the violations when a rule is broken" do
    # The sample app's web module does reach the repo, through a context.
    assert {:error, [%{"caller" => "SampleApp.Accounts.delete_users/0"}]} =
             Fathom.forbid(
               """
               SELECT caller FROM calls
               WHERE callee = 'SampleApp.Repo.delete_all/1'
               """,
               [],
               db_path()
             )
  end

  test "the database is read-only" do
    assert {:error, _reason} = Fathom.query("DELETE FROM functions", [], db_path())
  end
end
