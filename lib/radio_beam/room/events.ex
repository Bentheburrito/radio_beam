defmodule RadioBeam.Room.Events do
  @moduledoc """
  Helper functions for constructing room events
  """

  alias RadioBeam.Room.AuthorizedEvent
  alias Polyjuice.Util.Identifiers.V1.RoomAliasIdentifier
  alias Polyjuice.Util.RoomVersion

  def reference_hash(event_attrs, room_version) do
    case RoomVersion.compute_reference_hash(room_version, event_attrs) do
      # Events began using the URL-safe variant in Room Version 4.
      # It's not planned to support Room Versions 1 or 2 currently, since they
      # have a completely different (non-hash-based) schema for event IDs that
      # include the servername.
      {:ok, hash} when room_version == "3" -> {:ok, "$" <> Base.encode64(hash)}
      {:ok, hash} -> {:ok, "$" <> Base.url_encode64(hash)}
      :error -> {:error, :could_not_compute_reference_hash}
    end
  end

  @doc "Returns the attrs for a room message event."
  def message(room_id, sender_id, type, content) do
    %{
      "type" => type,
      "room_id" => room_id,
      "sender" => sender_id,
      "content" => content,
      "origin_server_ts" => System.os_time(:millisecond)
    }
  end

  @doc "Returns the attrs for a m.room.message event with content.msgtype m.text."
  def text_message(room_id, sender_id, message) do
    message(room_id, sender_id, "m.room.message", %{"msgtype" => "m.text", "body" => message})
  end

  def state(room_id, type, sender_id, content, state_key \\ "") do
    room_id
    |> message(sender_id, type, content)
    |> Map.put("state_key", state_key)
  end

  @doc """
  Returns an Enumerable of initial state events that should be sent into a Room
  after the given m.room.create event.
  """
  def initial_state_stream(%AuthorizedEvent{type: "m.room.create"} = create_event, opts \\ []) do
    %{room_id: room_id, sender: creator_id} = create_event

    event_from_optional_string = fn opt_name, event_fxn ->
      with str_value when is_binary(str_value) <- Keyword.get(opts, opt_name), do: event_fxn.(str_value)
    end

    maybe_canonical_alias_event =
      event_from_optional_string.(:alias, &canonical_alias(room_id, creator_id, &1, RadioBeam.server_name()))

    maybe_name_event = event_from_optional_string.(:name, &name(room_id, creator_id, &1))
    maybe_topic_event = event_from_optional_string.(:topic, &topic(room_id, creator_id, &1))

    visibility = Keyword.get(opts, :visibility, :private)
    preset = Keyword.get(opts, :preset, (visibility == :private && :private_chat) || :public_chat)
    direct? = Keyword.get(opts, :direct?, false)

    addl_state_events =
      opts
      |> Keyword.get(:addl_state_events, [])
      |> Stream.map(
        &state(room_id, Map.fetch!(&1, "type"), creator_id, Map.fetch!(&1, "content"), Map.fetch!(&1, "state_key"))
      )

    invite_events =
      opts
      |> Keyword.get(:invite, [])
      |> Stream.map(&membership(room_id, creator_id, &1, :invite, "New room invitation", direct?))

    [
      membership(room_id, creator_id, creator_id, :join, "Creator join event", direct?),
      power_levels(room_id, creator_id, Keyword.get(opts, :power_levels, %{})),
      maybe_canonical_alias_event
    ]
    |> Stream.concat(from_preset(preset, room_id, creator_id))
    |> Stream.concat(addl_state_events)
    |> Stream.concat([maybe_name_event, maybe_topic_event])
    |> Stream.concat(invite_events)
    # TOIMPL: 3pid invites
    |> Stream.concat(_3pid_invite_events = [])
    |> Stream.reject(&is_nil/1)
  end

  def create(room_id, creator_id, room_version, create_content) do
    create_content =
      create_content
      |> maybe_put_creator(room_version, creator_id)
      |> Map.put("room_version", room_version)

    state(room_id, "m.room.create", creator_id, create_content)
  end

  defp maybe_put_creator(content, version, creator_id) when version in ~w|1 2 3 4 5 6 7 8 9 10|,
    do: Map.put(content, "creator", creator_id)

  defp maybe_put_creator(content, _version, _creator_id), do: content

  @membership_values [:join, :invite, :leave, :kick, :ban]
  def membership(room_id, sender_id, subject_id, membership, reason \\ nil, direct? \\ false)
      when membership in @membership_values do
    content = membership_content(membership, reason, direct?)
    state(room_id, "m.room.member", sender_id, content, subject_id)
  end

  def power_levels(room_id, sender_id, content_overrides) do
    power_levels_content =
      sender_id
      |> default_power_level_content()
      |> Map.merge(content_overrides, fn
        _k, v1, v2 when is_map(v1) and is_map(v2) -> Map.merge(v1, v2)
        _k, _v1, v2 -> v2
      end)

    state(room_id, "m.room.power_levels", sender_id, power_levels_content)
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

  def canonical_alias(room_id, sender_id, alias_localpart, server_name) do
    case RoomAliasIdentifier.new({alias_localpart, server_name}) do
      {:ok, alias} ->
        state(room_id, "m.room.canonical_alias", sender_id, %{"alias" => to_string(alias)})

      {:error, error} ->
        raise error
    end
  end

  def from_preset(preset, room_id, sender_id) do
    join_rules_content = %{
      # TOIMPL: allow
      "join_rule" => (preset == :public_chat && "public") || "invite"
    }

    guest_access_content = %{
      "guest_access" => (preset == :public_chat && "forbidden") || "can_join"
    }

    [
      state(room_id, "m.room.join_rules", sender_id, join_rules_content),
      state(room_id, "m.room.history_visibility", sender_id, %{"history_visibility" => "shared"}),
      state(room_id, "m.room.guest_access", sender_id, guest_access_content)
    ]
  end

  def name(room_id, sender_id, name) do
    state(room_id, "m.room.name", sender_id, %{"name" => name})
  end

  def topic(room_id, sender_id, topic) do
    state(room_id, "m.room.topic", sender_id, %{"topic" => topic})
  end

  def redaction(room_id, sender_id, redacts, reason) do
    message(room_id, sender_id, "m.room.redaction", redaction_content(redacts, reason))
  end

  defp membership_content(membership, nil, direct?),
    do: %{"membership" => to_string(membership), "is_direct" => direct?}

  defp membership_content(membership, reason, direct?) when is_binary(reason),
    do: %{"membership" => to_string(membership), "reason" => reason, "is_direct" => direct?}

  defp redaction_content(redacts, nil), do: %{"redacts" => redacts}

  defp redaction_content(redacts, reason) when is_binary(reason),
    do: %{"redacts" => redacts, "reason" => reason}
end
