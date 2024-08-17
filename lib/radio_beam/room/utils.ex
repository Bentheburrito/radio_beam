defmodule RadioBeam.Room.Utils do
  @moduledoc """
  Utility functiosn for Room servers
  """
  require Logger

  alias Polyjuice.Util.Identifiers.V1.RoomAliasIdentifier
  alias RadioBeam.Room.Ops

  def put_event_and_handle(room, event, context \\ "an") do
    case Ops.put_events(room, [event]) do
      {:ok, %{latest_event_ids: [event_id]} = room} ->
        {:reply, {:ok, event_id}, room}

      {:error, :unauthorized} = e ->
        Logger.info("rejecting a(n) #{context} event for being unauthorized")
        {:reply, e, room}

      {:error, error} ->
        Logger.error("an error occurred trying to put a(n) #{context} event: #{inspect(error)}")
        {:reply, {:error, :internal}, room}
    end
  end

  def message_event(room_id, sender_id, type, content) do
    %{"type" => type, "room_id" => room_id, "sender" => sender_id, "content" => content}
  end

  def state_event(room_id, type, sender_id, content, state_key \\ "") do
    %{
      "content" => content,
      "room_id" => room_id,
      "sender" => sender_id,
      "state_key" => state_key,
      "type" => type
    }
  end

  @membership_values [:join, :invite, :leave, :kick, :ban]

  def create_event(room_id, creator_id, room_version, create_content) do
    create_content =
      create_content
      |> maybe_put_creator(room_version, creator_id)
      |> Map.put("room_version", room_version)

    state_event(room_id, "m.room.create", creator_id, create_content)
  end

  defp maybe_put_creator(content, version, creator_id) when version in ~w|1 2 3 4 5 6 7 8 9 10|,
    do: Map.put(content, "creator", creator_id)

  defp maybe_put_creator(content, _version, _creator_id), do: content

  def membership_event(room_id, sender_id, subject_id, membership, reason \\ nil)
      when membership in @membership_values do
    content = membership_event_content(membership, reason)
    state_event(room_id, "m.room.member", sender_id, content, subject_id)
  end

  def power_levels_event(room_id, sender_id, content_overrides) do
    power_levels_content =
      sender_id
      |> default_power_level_content()
      |> Map.merge(content_overrides, fn
        _k, v1, v2 when is_map(v1) and is_map(v2) -> Map.merge(v1, v2)
        _k, _v1, v2 -> v2
      end)

    state_event(room_id, "m.room.power_levels", sender_id, power_levels_content)
  end

  def default_power_level_content(creator_id) do
    %{
      "ban" => 50,
      "events" => %{},
      "events_default" => 0,
      "invite" => 0,
      "kick" => 50,
      "notifications" => %{"room" => 50},
      "redact" => 50,
      "state_default" => 50,
      "users" => %{creator_id => 100},
      "users_default" => 0
    }
  end

  def canonical_alias_event(room_id, sender_id, alias_localpart, server_name) do
    case RoomAliasIdentifier.new({alias_localpart, server_name}) do
      {:ok, alias} ->
        state_event(room_id, "m.room.canonical_alias", sender_id, %{"alias" => to_string(alias)})

      {:error, error} ->
        raise error
    end
  end

  def state_events_from_preset(preset, room_id, sender_id) do
    join_rules_content = %{
      # TOIMPL: allow
      "join_rule" => (preset == :public_chat && "public") || "invite"
    }

    guest_access_content = %{
      "guest_access" => (preset == :public_chat && "forbidden") || "can_join"
    }

    [
      state_event(room_id, "m.room.join_rules", sender_id, join_rules_content),
      state_event(room_id, "m.room.history_visibility", sender_id, %{"history_visibility" => "shared"}),
      state_event(room_id, "m.room.guest_access", sender_id, guest_access_content)
    ]
  end

  def name_event(room_id, sender_id, name) do
    state_event(room_id, "m.room.name", sender_id, %{"name" => name})
  end

  def topic_event(room_id, sender_id, topic) do
    state_event(room_id, "m.room.topic", sender_id, %{"topic" => topic})
  end

  defp membership_event_content(membership, nil), do: %{"membership" => to_string(membership)}

  defp membership_event_content(membership, reason) when is_binary(reason),
    do: %{"membership" => to_string(membership), "reason" => reason}
end
