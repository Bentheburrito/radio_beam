defmodule RadioBeam.User.ClientConfig do
  @moduledoc """
  Domain struct for a user's account data, as described in [Client
  Config](https://spec.matrix.org/latest/client-server-api/#client-config).

  Also contains stored EventFilters.
  """
  alias RadioBeam.User.EventFilter

  defstruct ~w|user_id account_data filters|a
  @type t() :: %__MODULE__{}

  def new!(user_id), do: %__MODULE__{user_id: user_id, account_data: %{}, filters: %{}}

  @doc """
  Puts global or room account data for a user. Any existing content for a scope
  + key is overwritten (not merged).
  """
  def put_account_data(config, scope \\ :global, type, content)

  @invalid_types ~w|m.fully_read m.push_rules|
  def put_account_data(_config, _scope, type, _content) when type in @invalid_types, do: {:error, :invalid_type}

  def put_account_data(%__MODULE__{} = config, scope, type, content) do
    account_data = RadioBeam.AccessExtras.put_nested(config.account_data, [scope, type], content)
    {:ok, struct!(config, account_data: account_data)}
  end

  @doc "Saves an event filter for the given User, overriding any existing entry."
  @spec put_event_filter(t(), EventFilter.t()) :: t()
  def put_event_filter(%__MODULE__{} = config, %EventFilter{} = filter) do
    put_in(config.filters[filter.id], filter)
  end

  @doc "Gets an event filter previously uploaded by the given User"
  @spec get_event_filter(t(), EventFilter.id()) :: {:ok, EventFilter.t()} | {:error, :not_found}
  def get_event_filter(%__MODULE__{} = config, filter_id) do
    with :error <- Map.fetch(config.filters, filter_id), do: {:error, :not_found}
  end

  def get_timeline_preferences(config, filter_or_filter_id \\ :none) do
    ignored_user_ids =
      MapSet.new(config.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

    event_filter = parse_filter_or_filter_id_with_default(config, filter_or_filter_id)

    %{ignored_user_ids: ignored_user_ids, filter: event_filter, account_data: config.account_data}
  end

  defp parse_filter_or_filter_id_with_default(config, filter_id) when is_binary(filter_id) do
    case get_event_filter(config, filter_id) do
      {:ok, filter} -> filter
      {:error, :not_found} -> EventFilter.new(%{})
    end
  end

  defp parse_filter_or_filter_id_with_default(_config, %EventFilter{} = inline_filter), do: inline_filter
  defp parse_filter_or_filter_id_with_default(_config, %{} = inline_filter), do: EventFilter.new(inline_filter)
  defp parse_filter_or_filter_id_with_default(_config, :none), do: EventFilter.new(%{})
end
