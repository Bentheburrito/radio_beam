defmodule RadioBeam.PDU do
  @moduledoc """
  A Persistent Data Unit described in room versions 3-10, representing an 
  event on the graph.
  """

  alias Polyjuice.Util.RoomVersion

  @types [
    event_id: :string,
    auth_events: {:array, :string},
    content: :map,
    depth: :integer,
    hashes: :map,
    origin_server_ts: :integer,
    prev_events: {:array, :string},
    redacts: :string,
    room_id: :string,
    sender: :string,
    signatures: :map,
    state_key: :string,
    type: :string,
    unsigned: :map
  ]
  @attrs Keyword.keys(@types)
  @required @attrs -- [:redacts, :state_key, :unsigned]

  use Memento.Table,
    attributes: @attrs,
    index: [:room_id],
    type: :set

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  def new(params, room_version) do
    params =
      params
      |> Map.put("origin_server_ts", :os.system_time(:millisecond))
      |> Map.put("", %{})
      # TOIMPL
      |> Map.put("hashes", %{})
      |> Map.put("signatures", %{})
      |> then(
        &Map.put_new_lazy(&1, "event_id", fn ->
          case RoomVersion.compute_reference_hash(room_version, &1) do
            {:ok, hash} -> "!#{Base.url_encode64(hash)}:#{RadioBeam.server_name()}"
            :error -> :could_not_compute_ref_hash
          end
        end)
      )

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required(@required)
    |> apply_action(:update)
  end

  @doc """
  Maps a collection of `event_id`s to PDUs
  """
  @spec get(Enumerable.t(String.t())) :: %{String.t() => t()}
  def get(ids) do
    Memento.transaction!(fn ->
      # TODO: looked a bit but not an obvious way to do an `in` guard in match 
      #       specs/Memento/mnesia, though is `read`ing for each id a
      #       performance issue?
      for id <- ids, into: %{}, do: {id, Memento.Query.read(__MODULE__, id)}
    end)
  end
end
