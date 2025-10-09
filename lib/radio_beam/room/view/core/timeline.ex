defmodule RadioBeam.Room.View.Core.Timeline do
  @moduledoc """
  Tracks a room's events and state that will be sent to clients when requested.
  """
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.EventMetadata
  alias RadioBeam.Room.View.Core.Timeline.TimestampToEventIDIndex
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.VisibilityGroup

  @attrs ~w|topological_id_to_event_id topological_id_ord_set event_metadata member_metadata visibility_groups timestamp_to_event_id_index|a
  @enforce_keys @attrs
  defstruct @attrs
  @typep t() :: %__MODULE__{}

  def new! do
    %__MODULE__{
      topological_id_to_event_id: %{},
      topological_id_ord_set: TopologicalID.OrderedSet.new!(),
      event_metadata: %{},
      member_metadata: %{},
      visibility_groups: %{},
      timestamp_to_event_id_index: TimestampToEventIDIndex.new!()
    }
  end

  def key_for(%{id: room_id}, _pdu), do: {:ok, {__MODULE__, room_id}}

  def handle_pdu(%__MODULE__{} = timeline, %Room{} = room, %PDU{} = pdu) do
    prev_events_topo_id_stream =
      timeline.event_metadata |> Map.take(pdu.prev_event_ids) |> Stream.map(& &1.topological_id)

    pdu_topo_id = TopologicalID.new!(pdu, prev_events_topo_id_stream)

    member_metadata =
      if pdu.event.type == "m.room.member" and pdu.event.content["membership"] == "join" do
        latest_topo_id = later_join_topo_id(timeline, pdu.event.state_key, pdu_topo_id)
        put_in(timeline.member_metadata[pdu.event.state_key], %{latest_known_join_topo_id: latest_topo_id})
      else
        timeline.member_metadata
      end

    visibility_group = VisibilityGroup.from_state!(room.state, pdu)
    visibility_group_id = VisibilityGroup.id(visibility_group)

    event_metadata =
      with {:ok, %{"event_id" => parent_event_id}} <- Map.fetch(pdu.event.content, "m.relates_to"),
           true <- Relationships.aggregable?(pdu) do
        timeline.event_metadata
        |> Map.update(
          parent_event_id,
          EventMetadata.new!(:unknown, visibility_group_id, [pdu.event.id]),
          &EventMetadata.append_bundled_event_id(&1, pdu.event.id)
        )
        |> Map.update(
          pdu.event.id,
          EventMetadata.new!(pdu_topo_id, visibility_group_id),
          &EventMetadata.put_topological_id(&1, pdu_topo_id)
        )
      else
        _ ->
          Map.update(
            timeline.event_metadata,
            pdu.event.id,
            EventMetadata.new!(pdu_topo_id, visibility_group_id),
            &EventMetadata.put_topological_id(&1, pdu_topo_id)
          )
      end

    struct!(timeline,
      topological_id_to_event_id: Map.put(timeline.topological_id_to_event_id, pdu_topo_id, pdu.event.id),
      topological_id_ord_set: TopologicalID.OrderedSet.put(timeline.topological_id_ord_set, pdu_topo_id),
      event_metadata: event_metadata,
      member_metadata: member_metadata,
      visibility_groups: Map.put(timeline.visibility_groups, visibility_group_id, visibility_group),
      timestamp_to_event_id_index:
        TimestampToEventIDIndex.put(timeline.timestamp_to_event_id_index, pdu.event.origin_server_ts, pdu.event.id)
    )
  end

  defp later_join_topo_id(timeline, user_id, pdu_topo_id) do
    case timeline.member_metadata[user_id][:latest_known_join_topo_id] do
      nil ->
        pdu_topo_id

      latest_known_join_topo_id ->
        if TopologicalID.compare(pdu_topo_id, latest_known_join_topo_id) == :gt do
          pdu_topo_id
        else
          latest_known_join_topo_id
        end
    end
  end

  defp put_vg_id_for_user(user_id_to_visibility_group, user_id, vg_id) do
    Map.update(user_id_to_visibility_group, user_id, MapSet.new([vg_id]), &MapSet.put(&1, vg_id))
  end

  @spec topological_stream(t(), {TopologicalID.t(), :forward | :backward} | :root | :tip) ::
          {Enumerable.t(Room.event_id()), TopologicalID.t(), :more | :done}
  def topological_stream(%__MODULE__{} = timeline, user_id, {%TopologicalID{} = from, direction}, fetch_pdu!) do
    latest_known_join_topo_id = get_in(timeline.member_metadata[user_id][:latest_known_join_topo_id]) || :never_joined

    timeline.topological_id_ord_set
    |> TopologicalID.OrderedSet.stream_from(from, direction)
    |> Stream.filter(&visible_to_user?(timeline, user_id, latest_known_join_topo_id, &1))
    |> Stream.map(fn topological_id ->
      event_id = Map.fetch!(timeline.topological_id_to_event_id, topological_id)

      event_visible? =
        fn {_event_id, metadata} ->
          visible_to_user?(timeline, user_id, latest_known_join_topo_id, metdata.topological_id)
        end

      visible_bundled_events =
        timeline.event_metadata[event_id].bundled_event_ids
        |> Stream.map(&{&1, Map.fetch!(timeline.event_metadata, &1)})
        |> Stream.filter(event_visible?)
        |> Enum.map(fn {event_id, metadata} -> Event.new!(metadata.topological_id, fetch_pdu!.(event_id), []) end)

      Event.new!(topological_id, fetch_pdu!.(event_id), visible_bundled_events)
    end)
  end

  def topological_stream(timeline, user_id, :root, fetch_pdu!),
    do: topological_stream(timeline, user_id, {timeline.set.first_id, :forward}, fetch_pdu!)

  def topological_stream(timeline, user_id, :tip, fetch_pdu!),
    do: topological_stream(timeline, user_id, {timeline.set.last_id, :backward}, fetch_pdu!)

  defp visible_to_user?(timeline, user_id, latest_known_join_topo_id, topological_id) do
    event_id = Map.fetch!(timeline.topological_id_to_event_id, topological_id)
    event_metadata = Map.fetch!(timeline.event_metadata, event_id)

    case event_metadata.visibility_group_id do
      :world_readable ->
        true

      event_visibility_group_id ->
        %VisibilityGroup{history_visibility: visibility_at_event} =
          event_visibility_group = Map.fetch!(timeline.visibility_groups, event_visibility_group_id)

        user_joined_after_event? = TopologicalID.compare(latest_known_join_topo_id, topological_id) == :gt

        user_id in event_visibility_group.joined or
          (visibility_at_event == "shared" and user_joined_after_event?) or
          (visibility_at_event == "invited" and user_id in event_visibility_group.invited and user_joined_after_event?)
    end
  end

  def get_visible_events(%__MODULE__{} = timeline, event_ids, user_id, fetch_pdu!) do
    latest_known_join_topo_id = get_in(timeline.member_metadata[user_id][:latest_known_join_topo_id]) || :never_joined

    event_visible? =
      fn {_event_id, metadata} ->
        visible_to_user?(timeline, user_id, latest_known_join_topo_id, metdata.topological_id)
      end

    event_ids
    |> Stream.map(&{&1, timeline.event_metadata[&1]})
    |> Stream.reject(fn {_event_id, maybe_metadata} -> is_nil(maybe_metadata) end)
    |> Stream.filter(event_visible?)
    |> Stream.map(fn {event_id, metadata} ->
      visible_bundled_events =
        timeline.event_metadata[event_id].bundled_event_ids
        |> Stream.map(&{&1, Map.fetch!(timeline.event_metadata, &1)})
        |> Stream.filter(event_visible?)
        |> Enum.map(fn {event_id, metadata} -> Event.new!(metadata.topological_id, fetch_pdu!.(event_id), []) end)

      Event.new!(metadata.topological_id, fetch_pdu!.(event_id), visible_bundled_events)
    end)
  end

  defmodule TopologicalID do
    @moduledoc """
    Opaque ID for an event ordered among other events.

    ## Internal

    TODO
    """
    alias RadioBeam.Room.PDU

    @attrs ~w|depth stream_number|a
    @enforce_keys @attrs
    defstruct @attrs
    @opaque t() :: %__MODULE__{}

    def new!(%PDU{} = pdu, prev_event_topo_ids) do
      depth = (prev_event_topo_ids |> Stream.map(& &1.depth) |> Enum.max(fn -> 0 end)) + 1
      %__MODULE__{depth: depth, stream_number: pdu.stream_number}
    end

    def group_key(%__MODULE__{} = tid), do: tid.depth

    def group_iterator(:forward), do: &(&1 + 1)
    def group_iterator(:backward), do: &(&1 - 1)

    def compare(%__MODULE__{} = tid, %__MODULE__{} = tid), do: :eq

    def compare(%__MODULE__{} = tid1, %__MODULE__{} = tid2) do
      if {tid1.depth, tid1.stream_number} > {tid2.depth, tid2.stream_number}, do: :gt, else: :lt
    end

    def parse_string("tid(" <> param_string) do
      with [depth_str, stream_num_str] <- String.split(param_string, ":"),
           {depth, ""} <- Integer.parse(depth_str),
           {stream_num, ")"} <- Integer.parse(stream_num_str) do
        %__MODULE__{depth: depth, stream_number: stream_num}
      else
        _ -> {:error, :invalid}
      end
    end

    def parse_string(_), do: {:error, :invalid}

    defimpl String.Chars do
      def to_string(topological_id), do: "tid(#{topological_id.depth}:#{topological_id.stream_number})"
    end

    defimpl Jason.Encoder do
      def encode(topological_id, opts), do: Jason.Encode.string(to_string(topological_id), opts)
    end

    defmodule Range do
      @moduledoc """
      Represents an inclusive, continuous selection of events from one
      TopologicalID to another.
      """
      @attrs ~w|lower upper|a
      @enforce_keys @attrs
      defstruct @attrs

      def new!(lower, upper) do
        case TopologicalID.compare(lower, upper) in ~w|lt eq|a do
          true -> %__MODULE__{lower: lower, upper: upper}
        end
      end

      def in?(%TopologicalID{} = tid, %__MODULE__{} = range) do
        TopologicalID.compare(tid, range.lower) in ~w|gt eq|a and
          TopologicalID.compare(tid, range.upper) in ~w|lt eq|a
      end
    end

    defmodule OrderedSet do
      alias RadioBeam.Room.View.Core.Timeline.TopologicalID

      # index: %{topo_group_key => [TopologicalID.t()]}
      defstruct index: %{}, first_id: nil, last_id: nil

      def new!, do: %__MODULE__{}

      def stream_from(%__MODULE__{} = set, %TopologicalID{} = from, direction) do
        order_fxn = if direction == :forward, do: & &1, else: &Enum.reverse/1

        from
        |> TopologicalID.group_key()
        |> Stream.iterate(TopologicalID.group_iterator(direction))
        |> Stream.flat_map(&(set.index |> Map.get(&1, []) |> order_fxn.()))
      end

      def put(%__MODULE__{} = set, %TopologicalID{} = topo_id) do
        first_id =
          cond do
            is_nil(set.first_id) -> topo_id
            TopologicalID.compare(set.first_id, topo_id) == :lt -> set.first_id
            :else -> topo_id
          end

        last_id =
          cond do
            is_nil(set.last_id) -> topo_id
            TopologicalID.compare(set.last_id, topo_id) == :gt -> set.last_id
            :else -> topo_id
          end

        struct!(set,
          index: Map.update(set.index, TopologicalID.group_key(topo_id), [topo_id], &put_in_list/2),
          first_id: first_id,
          last_id: last_id
        )
      end

      defp put_in_list(topo_id_list, topo_id), do: put_in_list(topo_id_list, topo_id, [])

      defp put_in_list([last_topo_id], topo_id, topo_id_list_reversed) do
        # if last_topo_id comes after (is greater than) topo_id, keep it the
        # last ID in the list...
        if TopologicalID.compare(last_topo_id, topo_id) == :gt do
          Enum.reverse([last_topo_id, topo_id | topo_id_list_reversed])
        else
          # ...else it should be 2nd to last, and topo_id is the new last ID
          Enum.reverse([topo_id, last_topo_id | topo_id_list_reversed])
        end
      end

      defp put_in_list([tid1, tid2 | topo_id_list], topo_id, topo_id_list_reversed) do
        if TopologicalID.Range.in?(topo_id, TopologicalID.Range.new!(tid1, tid2)) do
          Enum.reverse(topo_id_list_reversed) ++ [tid1, topo_id, tid2 | topo_id_list]
        else
          put_in_list([tid2 | topo_id_list], topo_id, [tid1 | topo_id_list_reversed])
        end
      end
    end
  end

  defmodule VisibilityGroup do
    defstruct ~w|joined invited history_visibility|a

    def from_state!(state, pdu) do
      init_group =
        case Room.State.fetch_at(state, "m.room.history_visibility", pdu) do
          {:ok, %PDU{} = pdu} -> %__MODULE__{history_visibility: pdu.event.content["history_visibility"]}
          {:error, :not_found} -> %__MODULE__{history_visibility: "shared"}
        end

      state
      |> Room.State.get_all_at(pdu)
      |> Enum.reduce(init_group, fn
        {{"m.room.member", user_id}, %PDU{event: %{state_key: user_id}} = pdu}, %__MODULE__{} = group ->
          case pdu.event.content["membership"] do
            "join" -> put_in(group.joined, user_id)
            "invite" -> put_in(group.invited, user_id)
            _ -> group
          end

        _, group ->
          group
      end)
    end

    def id(%__MODULE__{history_visibility: "world_readable"}), do: :world_readable
    def id(%__MODULE__{} = group), do: :crypto.hash(:sha256, :erlang.term_to_binary(group))
  end

  defmodule Event do
    alias RadioBeam.Room.AuthorizedEvent

    defstruct [:order_id, :bundled_events] ++ AuthorizedEvent.keys()

    def new!(id, %PDU{event: event}, bundled_events) when is_struct(id, TopologicalID) or id == :unknown do
      struct!(
        __MODULE__,
        event
        |> Map.from_struct()
        |> Map.put(:order_id, id)
        |> Map.put(:bundled_events, bundled_events)
      )
    end

    # TOIMPL: choose client or federation format based on filter
    @cs_event_keys [:content, :event_id, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
    def to_map(%__MODULE__{} = event, room_version) do
      event
      |> Map.take(@cs_event_keys)
      |> adjust_redacts_key(room_version)
      |> case do
        %{state_key: :none} = event -> Map.delete(event, :state_key)
        event -> event
      end
    end

    @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
    defp adjust_redacts_key(%{type: "m.room.redaction"} = event, room_version)
         when room_version in @pre_v11_format_versions do
      {redacts, content} = Map.pop!(event.content, "redacts")

      event
      |> Map.put(:redacts, redacts)
      |> Map.put(:content, content)
    end

    defp adjust_redacts_key(event, _room_version), do: event
  end

  defmodule EventMetadata do
    @enforce_keys ~w|topological_id|a
    defstruct topological_id: nil, visibility_group_id: nil, bundled_event_ids: []

    def new!(%TopologicalID{} = topological_id, visibility_group_id, bundled_event_ids \\ []) do
      %__MODULE__{
        topological_id: topological_id,
        visibility_group_id: visibility_group_id,
        bundled_event_ids: bundled_event_ids
      }
    end

    def put_topological_id(%__MODULE__{} = metadata, %TopologicalID{} = id), do: struct!(metadata, topological_id: id)

    def append_bundled_event_id(%__MODULE__{} = metadata, event_id) do
      update_in(metadata.bundled_event_ids, &[event_id | &1])
    end
  end

  defmodule TimestampToEventIDIndex do
    @round_to_multiples_of :timer.minutes(20)
    @default_cutoff :timer.hours(24)

    # index: %{rounded_origin_server_ts => [{origin_server_ts, event_id}]}
    defstruct index: %{}

    def new!, do: %__MODULE__{index: %{}}

    def put(%__MODULE__{} = ts_index, origin_server_ts, event_id) do
      rounded_timestamp = round_timestamp(origin_server_ts)

      update_in(ts_index.index[rounded_timestamp], fn
        nil -> [{origin_server_ts, event_id}]
        # TODO: maybe optimize if necessary
        ordered_pairs -> Enum.sort_by([{origin_server_ts, event_id} | ordered_pairs], &elem(&1, 0))
      end)
    end

    @doc """
    Returns event IDs whose `origin_server_ts` is closest to the given unix
    `timestamp` in the direction of `dir`.
    """
    def stream_nearest_event_ids(%__MODULE__{index: index}, timestamp, dir)
        when is_integer(timestamp) and dir in ~w|forward backward|a do
      rounded_timestamp = round_timestamp(timestamp)
      to_add = if dir == :forward, do: @round_to_multiples_of, else: -@round_to_multiples_of

      keep_taking? =
        if dir == :forward do
          fn {origin_server_ts, _event_id} -> origin_server_ts > timestamp + @default_cutoff end
        else
          fn {origin_server_ts, _event_id} -> origin_server_ts < timestamp - @default_cutoff end
        end

      rounded_timestamp
      |> Stream.iterate(&(&1 + to_add))
      |> Stream.flat_map(&Map.get(index, &1, []))
      |> Stream.take_while(keep_taking?)

      # !! This needs to be done in the calling code that has user visibility info
      # if dir == :forward, Enum.find first {origin_ts, event_id} where origin_ts >= timestamp
      # if dir == :backward, reverse list, then Enum.find first {origin_ts, event_id} where origin_ts <= timestamp
    end

    defp round_timestamp(timestamp), do: timestamp - rem(timestamp, @round_to_multiples_of)
  end
end
