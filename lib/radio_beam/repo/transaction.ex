defmodule RadioBeam.Repo.Transaction do
  @moduledoc """
  A wrapper over `Memento`'s transactions - provides a consistent interface to
  compose fxns (functions) within an `:mnesia` transaction. Similar to Ecto's
  `Ecto.Multi`.

  ### Flow

  The intended flow is:

  - Create a new `%Transaction{}` object with `new/0`. This is an opaque
    struct, which means you should never create/update/access fields directly,
    though you can pattern match against the struct.
  - Add functions that deal with `Memento.Query` calls with `add_fxn/3`.
  - Finally, run the functions in the order they were added with `execute/1`,
    returning the result of the last function (or the first error encountered).

  The second argument for `add_fxn/3` is a function name. This can be any term.
  The name is only used when an error is encountered to help the caller
  identify which function failed. Note that duplicate names are allowed, but
  not recommended.

  Every function must be an arity 0 or 1. If its arity is 1, it will be given
  the previous function's result. Every function must return either `{:ok, result}`
  or `{:error, error}`. An error tuple will abort the transaction.

  Note: `Transaction`s can be nested if a function creates and `execute/1`s
  another `Transaction`. However, this will not result in nested `:mnesia`
  transactions, as `execute/1` checks for this situation. This means a nested
  `Transaction` will finish executing before its parent continues, and abort
  the entire transaction if one of its functions errors. However, again, unique
  function names are not enforced, so it's up to you to provide distinct names
  to make identifying the source of any given error straightforward.
  """

  require Logger

  @type fxn_name() :: any()

  @typedoc """
  Every function in a `Transaction` is given the previous function's result (if
  its arity is 1). The first function will receive `:txn_begin`.
  """
  @type fxn_param() :: :txn_begin | any()
  @type fxn_result() :: {:ok, any()} | {:error, any()}

  @type result() :: {:ok, any()} | {:error, fxn_name(), :not_found | any()}

  @opaque t() :: %__MODULE__{fxn_chain: [{fxn_name(), (fxn_param() -> any())}]}
  defstruct fxn_chain: []

  def new, do: %__MODULE__{}
  def new(fxn_chain) when is_list(fxn_chain), do: Enum.reduce(fxn_chain, new(), &add_fxn(&2, elem(&1, 0), elem(&1, 1)))

  def add_fxn(%__MODULE__{} = txn, fxn_name, fxn) when is_function(fxn, 1) or is_function(fxn, 0) do
    Ecto.Multi
    %__MODULE__{txn | fxn_chain: [{fxn_name, fxn} | txn.fxn_chain]}
  end

  def execute(%__MODULE__{} = txn) do
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
      fxn = if is_function(fxn, 1), do: fn -> fxn.(prev_result) end, else: fxn

      try do
        case fxn.() do
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
