defmodule RadioBeam.Repo.Transaction do
  @moduledoc """
  A wrapper over `Memento`'s transactions - provides a consistent interface to
  compose fxns (functions) within an `:mnesia` transaction.

  ### Flow

  The intended flow is:

  - Create a new `%Transaction{}` object with `new/0`. This is an opaque
    struct, which means you should never create/update/access fields directly.
  - Add functions that deal with `Memento.Query` calls with `add_fxn/3`.
  - Finally, run the functions in the order they were added with `execute/1`,
    returning the result of the last function (or the first error encountered).

  The second argument for `add_fxn/3` is a function name. This can be any term.
  The name is only used when an error is encountered to help the caller
  identify which function failed. Note that duplicate names are allowed, but
  not recommended.

  Note: `Transaction`s can be nested if a function creates and `execute/1`s
  another `Transaction`. However, this will not result in nested `:mnesia`
  transactions, as `execute/1` checks for this situation. This means a nested
  `Transaction` will finish executing before its parent continues, and abort
  the entire transaction if one of its functions errors. However, again, unique
  function names are not enforced, so it's up to you to provide distinct names
  to make identifying the source of any given error straightforward.
  """

  @typedoc """
  Every function in a `Transaction` is given the previous function's result.
  The first function will receive `:txn_begin`.
  """
  require Logger

  @type fxn_name() :: any()
  @type fxn_param() :: :txn_begin | any()
  @type fxn_result() :: {:ok, any()} | {:error, any()}

  @type result() :: {:ok, any()} | {:error, fxn_name(), :not_found | any()}

  @opaque t() :: %__MODULE__{fxn_chain: [{fxn_name(), (fxn_param() -> any())}]}
  defstruct fxn_chain: []

  def new, do: %__MODULE__{}

  def new(fxn_chain) when is_list(fxn_chain), do: Enum.reduce(fxn_chain, new(), &add_fxn(&2, elem(&1, 0), elem(&1, 1)))

  # TODO NEXT = PROBABLY WANT A VARIATION OF THIS THAT JUST DISCARDS THE LAST
  # FUNCTION'S RESULT
  def add_fxn(%__MODULE__{} = txn, fxn_name, fxn) when is_function(fxn, 1) do
    %__MODULE__{txn | fxn_chain: [{fxn_name, fxn} | txn.fxn_chain]}
  end

  def execute(%__MODULE__{} = txn) do
    # ... will this work?
    if Memento.Transaction.inside?() do
      execute(txn.fxn_chain)
    else
      case Memento.transaction(fn -> execute(txn.fxn_chain) end) do
        {:ok, _} = result -> result
        {:error, {:transaction_aborted, {:fxn_error, fxn_name, error}}} -> {:error, fxn_name, error}
        {:error, error} -> report_fatal_error(txn, error)
      end
    end
  end

  def execute(fxn_chain) when is_list(fxn_chain) do
    fxn_chain
    |> Enum.reverse()
    |> Enum.reduce(:txn_begin, fn {name, fxn}, prev_result ->
      try do
        case fxn.(prev_result) do
          {:ok, result} -> result
          {:error, error} -> Memento.Transaction.abort({:fxn_error, name, error})
        end
      rescue
        error -> Memento.Transaction.abort({:fxn_error, name, error})
      end
    end)
  end

  # def map_memento_result(result) do
  #   case result do
  #     {:ok, nil} -> {:error, :not_found}
  #     {:ok, result} -> :put_a_pin_in_this_for_now
  #   end
  # end

  defp report_fatal_error(txn, error) do
    Logger.error("""
    A fatal/unknown error occurred running the following `RadioBeam.Repo.Transaction`:
    #{inspect(txn)}
    """)

    raise inspect(error)
  end

  defimpl Inspect do
    def inspect(txn, opts) do
      Inspect.Algebra.concat(["RadioBeam.Repo.Transaction.new(", Inspect.List.inspect(txn.fxn_chain, opts), ")"])
    end
  end
end
