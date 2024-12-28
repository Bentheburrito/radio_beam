defmodule RadioBeam.Room.EventGraph.Core do
  @moduledoc """
  Functional core for EventGraph
  """

  import Ecto.Changeset

  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.PDU
  alias RadioBeam.Room

  @pdu_schema PDU.schema()
  @pdu_schema_keys Map.keys(@pdu_schema)

  @doc """
  Redacts the given PDU according to the rules of the given room version.
  """
  @spec redact_pdu(PDU.t(), PDU.t(), room_version :: String.t()) :: {:ok, PDU.t()} | {:error, Ecto.Changeset.t()}
  def redact_pdu(%PDU{} = to_redact, %PDU{} = redaction_pdu, room_version) do
    event = PDU.to_event(to_redact, room_version, :strings, :federation)
    {:ok, redacted_params} = RoomVersion.redact(room_version, event)

    {to_redact, @pdu_schema}
    |> cast(redacted_params, @pdu_schema_keys, empty_values: [])
    |> put_change(:parent_id, :root)
    |> put_change(:unsigned, %{"redacted_because" => PDU.to_event(redaction_pdu, room_version)})
    |> validate_required(@pdu_schema_keys -- ~w|state_key|a)
    |> apply_v11_redaction_changes(redacted_params, room_version)
    |> apply_action(:update)
  end

  # for the Client-Server API only - add an event to the DAG, appending it to the given PDU
  # does not persist, just functional/biz logic
  def append(%Room{} = room, %PDU{} = parent, event_params), do: append(room, [parent], event_params)

  def append(%Room{} = room, parents, event_params) when is_list(parents) do
    with {:ok, dag_params} <- calculate_dag_params(event_params["type"], parents),
         params = event_params |> Map.merge(dag_params) |> default_params(room.state),
         {:ok, event_id} <- calculate_event_id(room.version, params),
         params = Map.put(params, "event_id", event_id),
         {:ok, %PDU{} = pdu} <- new_pdu(params, room.version) do
      {:ok, pdu}
    end
  end

  # we don't need strictly monotonic nums in prod, but it's a nice property for
  # test assertions. In the future `arrival_order` could be passed to this fxn
  # from the caller (`Room`)
  @order_params if Mix.env() == :test, do: [:monotonic], else: []
  defp default_params(event_params, current_room_state) do
    arrival_time = Map.get_lazy(event_params, "arrival_time", fn -> :os.system_time(:millisecond) end)
    origin_server_ts = Map.get(event_params, "origin_server_ts", arrival_time)

    event_params
    |> Map.put_new("arrival_time", arrival_time)
    |> Map.put_new_lazy("arrival_order", fn -> :erlang.unique_integer(@order_params) end)
    |> Map.put("state_events", Enum.map(current_room_state, &elem(&1, 1)["event_id"]))
    |> Map.put(
      "current_visibility",
      get_in(current_room_state[{"m.room.history_visibility", ""}]["content"]["history_visibility"]) || "shared"
    )
    |> Map.put_new("origin_server_ts", origin_server_ts)
    # TOIMPL
    |> Map.put_new("hashes", %{})
    |> Map.put_new("signatures", %{})
    |> Map.put_new("unsigned", %{})
  end

  defp calculate_dag_params("m.room.create", []) do
    {:ok,
     %{
       "depth" => 1,
       "chunk" => 0,
       "prev_events" => []
     }}
  end

  defp calculate_dag_params(_type, parent_pdus) do
    case parent_pdus do
      [%{chunk: chunk, depth: depth} | _] ->
        if Enum.all?(parent_pdus, &(&1.depth == depth and &1.chunk == chunk)) do
          {:ok,
           %{
             # a new PDU will have its parents' depth + 1
             "depth" => depth + 1,
             # a new PDU belongs to the same chunk as its parents
             "chunk" => chunk,
             "prev_events" => Enum.map(parent_pdus, & &1.event_id)
           }}
        else
          # if the chunk or depth of parents are not the same, we cannot represent
          # that in our data model...
          {:error, :unrepresentable_parent_rel}
        end

      [] ->
        {:error, :empty_parent_list}
    end
  end

  defp calculate_event_id(room_version, params) do
    case RoomVersion.compute_reference_hash(room_version, params) do
      # Events began using the URL-safe variant in Room Version 4.
      # It's not planned to support Room Versions 1 or 2 currently, since they
      # have a completely different (non-hash-based) schema for event IDs that
      # include the servername.
      {:ok, hash} when room_version == "3" -> {:ok, "$" <> Base.encode64(hash)}
      {:ok, hash} -> {:ok, "$" <> Base.url_encode64(hash)}
      :error -> {:error, :could_not_compute_reference_hash}
    end
  end

  defp new_pdu(params, room_version) do
    {%PDU{}, @pdu_schema}
    |> cast(params, @pdu_schema_keys, empty_values: [])
    |> put_change(:parent_id, get_in(params["content"], ~w|m.relates_to event_id|) || :root)
    |> validate_required(@pdu_schema_keys -- ~w|state_key|a)
    |> apply_v11_redaction_changes(params, room_version)
    |> apply_action(:insert)
  end

  @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
  defp apply_v11_redaction_changes(changeset, %{"type" => "m.room.redaction"} = params, version)
       when version not in @pre_v11_format_versions do
    update_change(changeset, :content, fn content ->
      # %PDU{} has the V11 shape, but we want to be backwards-compatible with older versions
      Map.put_new_lazy(content, "redacts", fn -> Map.fetch!(params, "redacts") end)
    end)
  end

  defp apply_v11_redaction_changes(changeset, _params, _room_version), do: changeset

  def build_window_guards(from_pdu, to_pdu_or_limit, dir) do
    case {from_pdu.depth, to_pdu_or_limit, dir} do
      {from_depth, :limit, :backward} ->
        {:ok, [{:"=<", :"$1", from_depth}]}

      {from_depth, :limit, :forward} ->
        {:ok, [{:>=, :"$1", from_depth}]}

      {from_depth, %{depth: to_depth}, :backward} when from_depth >= to_depth ->
        {:ok, [{:andalso, {:>, :"$1", to_depth}, {:"=<", :"$1", from_depth}}]}

      {from_depth, %{depth: to_depth}, :forward} when from_depth <= to_depth ->
        {:ok, [{:andalso, {:>=, :"$1", from_depth}, {:<, :"$1", to_depth}}]}

      _params_that_dont_make_sense ->
        {:error, :invalid_options}
    end
  end
end
