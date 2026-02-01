defmodule RadioBeam.Sync.Source do
  @moduledoc """
  The `RadioBeam.Sync.Source` behaviour defines how to pull data for a
  particular data source during a /sync request. The implementing module must
  check for new data, and communicate the status of its update by sending
  messages to the `sink_pid`. See each callback's documentation for more
  information.
  """
  alias RadioBeam.AccessExtras
  alias RadioBeam.Sync.Source
  alias RadioBeam.Sync.Source.NextBatch

  @attrs ~w|state mod key|a
  @enforce_keys @attrs
  defstruct @attrs
  @opaque t() :: %__MODULE__{}

  @typedoc """
  A source key is any term that allows the `Sync.Source` to identify the data
  source it should sync with. For example, a source that fetches new events for
  a user might use the key `{room_id, user_id}`, which should be enough
  information to query a room's timeline and filter events by the given user.
  """
  @type key() :: term()

  @typedoc """
  The result of a `Sync.Source`. This can be any struct that implements the
  `JSON.Encoder` protocol.
  """
  @type result() :: term()

  @typedoc """
  Any term that encodes to a URL-safe string marking the point in time up to
  which the given `result` contains data.

  This batch token is encoded alongside other batch tokens to make up a
  /sync "since token." **It should NEVER contain an ampersand character
  (`&`).**

  This same batch token will be included in follow-up calls to
  `c:Sync.Source.run/3` with the same key. It should be used to prevent
  returning data "older than" this token.
  """
  @type next_batch_token() :: term()

  @type next_batch_instruction() :: next_batch_token() | {:next_batch, key(), next_batch_token()}

  @type source_state() ::
          :working | :waiting | {:no_update, next_batch_instruction()} | {:done, result(), next_batch_instruction()}

  @type input() ::
          :timeout
          | :account_data
          | :user_id
          | :device_id
          | :event_filter
          | :full_state?
          | :full_last_batch
          | :ignored_user_ids
          | :known_memberships

  @doc """
  Returns a list of `t:input`s this Source requires to run. The `last_batch`
  key will always be given to `c:run/3`, even when this is an initial sync (in
  which case it will be set to `nil`).
  """
  @callback inputs() :: [input()]

  @doc """
  Runs the source, fetching data to return in the /sync response.

  This callback needs to communicate its status with the `sink_pid` process.
  The general flow should look something like this:

  1. Subscribe to any relevant PubSub topics
  1. Check for new data since the last sync. 
  1. If there is no new data:
    1. use `Source.notify_waiting/2` to inform `sink_pid`.
    1. wait for new data to become available, then proceed to the next step
  1. If there is new data, return an ok tuple with the result and next batch
    value.

  The callback may also return a 2-tuple of `{:no_update,
  t:next_batch_instruction}` to indicate that there is no new data available,
  and the `sink_pid` shouldn't wait for it.
  """
  @callback run(inputs :: %{input() => term()}, key(), sink_pid :: pid()) ::
              {:no_update, next_batch_instruction()} | {:ok, result(), next_batch_instruction()}

  @doc """
  The full JSON path in the /sync response under which the JSON-encoded
  `result` is put.
  """
  @callback top_level_path(key(), result()) :: [String.t()]

  defp new!(mod, key) when is_atom(mod) when is_binary(key), do: %__MODULE__{state: :working, mod: mod, key: key}
  defp new!(mod, key) when is_atom(mod), do: %__MODULE__{state: :working, mod: mod, key: inspect(key)}
  defp new!(mod) when is_atom(mod), do: %__MODULE__{state: :working, mod: mod, key: inspect(mod)}

  def sync_v2_sources(joined_room_ids, invited_room_ids, maybe_last_sync_token) do
    incremental_sync_sources =
      if is_nil(maybe_last_sync_token),
        do: [],
        else: [new!(Source.CryptoIdentityUpdates)]

    Enum.concat([
      [
        new!(Source.AccountDataUpdates),
        new!(Source.InvitedRoom),
        new!(Source.JoinedRoom),
        new!(Source.ToDeviceMessage)
      ],
      incremental_sync_sources,
      Stream.map(joined_room_ids, &new!(Source.ParticipatingRoom, &1)),
      Stream.map(invited_room_ids, &new!(Source.InvitedRoom, &1))
    ])
  end

  def run(%__MODULE__{} = source, inputs, sink_pid) do
    case source.mod.run(inputs, source.key, sink_pid) do
      {:ok, result, next_batch} -> {:sync_data, source.key, result, next_batch}
      {:no_update, next_batch} -> {:sync_data, source.key, :no_update, next_batch}
    end
  end

  def notify_waiting(sink_pid, key), do: send(sink_pid, {:sync_waiting, key})

  def handle_message(%__MODULE__{key: key} = source, {:sync_data, key, result, next_batch}) do
    case result do
      :no_update -> put_in(source.state, {:no_update, next_batch})
      result -> put_in(source.state, {:done, result, next_batch})
    end
  end

  def handle_message(%__MODULE__{key: key} = source, {:sync_waiting, key}) do
    put_in(source.state, :waiting)
  end

  def put_no_update(%__MODULE__{} = source), do: put_in(source.state, {:no_update, nil})

  def state(%__MODULE__{state: state}), do: state
  def key(%__MODULE__{key: key}), do: key

  def aggregate_results(sources, maybe_since) do
    Enum.reduce(sources, %{"next_batch" => NextBatch.new!(System.os_time(:millisecond))}, fn
      %Source{state: {:done, result, next_batch}} = source, sync_result ->
        top_level_path = source.mod.top_level_path(source.key, result)

        sync_result
        |> AccessExtras.put_nested(top_level_path, result)
        |> Map.update!("next_batch", &NextBatch.put(&1, source.key, next_batch))

      %Source{state: {:no_update, next_batch}} = source, sync_result ->
        Map.update!(sync_result, "next_batch", &NextBatch.put(&1, source.key, next_batch))

      %Source{state: state}, sync_result when state in ~w|working waiting|a and is_nil(maybe_since) ->
        sync_result

      %Source{state: state} = source, sync_result when state in ~w|working waiting|a ->
        case NextBatch.fetch(maybe_since, source.key) do
          {:ok, last_batch} -> Map.update!(sync_result, "next_batch", &NextBatch.put(&1, source.key, last_batch))
          {:error, :not_found} -> sync_result
        end
    end)
  end

  defmodule NextBatch do
    @moduledoc """
    Captures details about the information sent to a device in a previous call
    to /sync. This token can be given to future calls to /sync to request new
    information since the last call. These tokens can also be provided at other
    APIs (like /messages) to paginate, or otherwise scope results to
    before/after a particular point-in-time.
    """
    defstruct timestamp: 0, kvs: %{}, dir: :backward

    def new!(ts) when is_integer(ts) and ts > 0, do: %__MODULE__{timestamp: ts}
    def new!(ts, %{} = kvs) when is_integer(ts) and ts > 0, do: %__MODULE__{timestamp: ts, kvs: kvs}
    def new!(ts, kvs, dir) when dir in ~w|backward forward|a, do: ts |> new!(kvs) |> struct!(dir: dir)

    def decode(maybe_encoded_batch) do
      case URI.decode_query(maybe_encoded_batch) do
        %{"timestamp" => ts_str} = kvs ->
          case Integer.parse(ts_str) do
            {ts, ""} ->
              dir =
                case Map.get(kvs, "dir", "backward") do
                  "backward" -> :backward
                  "forward" -> :forward
                  _ -> :backward
                end

              kvs = kvs |> Map.delete("timestamp") |> Map.delete("dir")
              {:ok, new!(ts, kvs, dir)}

            _else ->
              {:error, :malformed_batch_token}
          end

        _else ->
          {:error, :malformed_batch_token}
      end
    end

    def put(batch, _source_key, {:next_batch, k, v}), do: put_in(batch.kvs[k], v)
    def put(batch, k, v), do: put_in(batch.kvs[k], v)

    def fetch(batch, k) do
      with :error <- Map.fetch(batch.kvs, k), do: {:error, :not_found}
    end

    def timestamp(%__MODULE__{timestamp: timestamp}), do: timestamp

    def direction(%__MODULE__{dir: dir}), do: dir

    def topologically_equal?(%__MODULE__{} = nb1, %__MODULE__{} = nb2) do
      nb1.kvs == nb2.kvs and nb1.dir == nb2.dir
    end

    def to_map(batch) do
      batch.kvs
      |> Map.put("timestamp", batch.timestamp)
      |> Map.put("dir", batch.dir)
      |> Stream.reject(fn {_k, v} -> is_nil(v) end)
    end

    defimpl JSON.Encoder do
      def encode(batch, encoder) do
        batch
        |> to_string()
        |> JSON.Encoder.BitString.encode(encoder)
      end
    end

    defimpl String.Chars do
      def to_string(batch) do
        batch.kvs
        |> Map.put("timestamp", batch.timestamp)
        |> Map.put("dir", batch.dir)
        |> Stream.reject(fn {_k, v} -> is_nil(v) end)
        |> URI.encode_query()
      end
    end
  end
end
