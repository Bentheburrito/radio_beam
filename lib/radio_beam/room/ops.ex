defmodule RadioBeam.Room.Ops do
  @moduledoc """
  ❗This is a private module intended to only be used by `Room` GenServers. It 
  provides an API for side-effect operations (ops) related to rooms, such as 
  atomic DB actions, PubSub broadcasts, etc.
  """

  alias RadioBeam.Repo
  alias RadioBeam.PDU
  alias RadioBeam.Room

  def persist_with_pdus(%Room{} = room, pdus) do
    Repo.one_shot(fn ->
      addl_actions =
        for %PDU{} = pdu <- pdus, do: pdu |> PDU.persist() |> get_pdu_followup_actions()

      room = Memento.Query.write(room)

      addl_actions
      |> List.flatten()
      |> Stream.filter(&is_function(&1))
      |> Enum.find_value({:ok, room}, fn action ->
        case action.() do
          {:error, _} = error -> error
          _result -> false
        end
      end)
    end)
  end

  defp get_pdu_followup_actions(%PDU{type: "m.room.canonical_alias"} = pdu) do
    for room_alias <- [pdu.content["alias"] | Map.get(pdu.content, "alt_aliases", [])], not is_nil(room_alias) do
      fn -> Room.Alias.put(room_alias, pdu.room_id) end
    end
  end

  # TOIMPL: add room to published room list if visibility option was set to :public
  defp get_pdu_followup_actions(%PDU{}), do: nil
end
