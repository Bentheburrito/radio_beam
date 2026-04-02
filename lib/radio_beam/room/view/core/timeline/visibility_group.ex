defmodule RadioBeam.Room.View.Core.Timeline.VisibilityGroup do
  @moduledoc false
  defstruct joined: MapSet.new(), invited: MapSet.new(), history_visibility: "shared"

  def from_state!(state_mapping, event_content) do
    init_group =
      case Map.fetch(state_mapping, {"m.room.history_visibility", ""}) do
        {:ok, event_id} -> %__MODULE__{history_visibility: Map.fetch!(event_content, event_id)["history_visibility"]}
        :error -> %__MODULE__{history_visibility: "shared"}
      end

    Enum.reduce(state_mapping, init_group, fn
      {{"m.room.member", user_id}, event_id}, %__MODULE__{} = group ->
        case Map.fetch!(event_content, event_id) do
          %{"membership" => "join"} -> update_in(group.joined, &MapSet.put(&1, user_id))
          %{"membership" => "invite"} -> update_in(group.invited, &MapSet.put(&1, user_id))
          _ -> group
        end

      _, group ->
        group
    end)
  end

  def id(%__MODULE__{history_visibility: "world_readable"}), do: :world_readable
  def id(%__MODULE__{} = group), do: :crypto.hash(:sha256, :erlang.term_to_binary(group))
end
