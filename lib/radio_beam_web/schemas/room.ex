defmodule RadioBeamWeb.Schemas.Room do
  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.InstantMessaging

  def invite do
    %{"user_id" => &Schema.user_id/1, "reason" => optional(:string)}
  end

  def join do
    # TOIMPL: third_party_signed
    %{"third_party_signed" => optional(:any), "reason" => optional(:string)}
  end

  def create do
    %{available: available_room_versions, default: default_room_version} =
      Application.get_env(:radio_beam, :capabilities)[:"m.room_versions"]

    %{
      "creation_content" => optional(content_schema()),
      "initial_state" => optional(:any),
      "invite" => optional(:any),
      "invite_3pid" => optional(:any),
      "is_direct" => optional(:boolean),
      "name" => optional(:string),
      "power_level_content_override" => [:any, default: %{}],
      "preset" =>
        optional(
          Schema.enum(%{
            "private_chat" => :private_chat,
            "public_chat" => :public_chat,
            "trusted_private_chat" => :trusted_private_chat
          })
        ),
      "room_alias_name" => optional(&room_localpart/1),
      "room_version" => [Schema.enum(Map.keys(available_room_versions)), default: default_room_version],
      "topic" => optional(:string),
      "visibility" => [Schema.enum(%{"private" => :private, "public" => :public}), default: :private]
    }
  end

  # add event-specific content schema enforcement here
  def send(%{"event_type" => "m.room.message"}), do: &InstantMessaging.message_content/1
  def send(_params), do: %{}

  defp content_schema() do
    %{
      "m.federate" => [:boolean, default: true],
      "predecessor" => optional(&Schema.room_id/1),
      "type" => optional(:string),
      # these will just be overwritten
      "room_version" => optional(:any),
      "creator" => optional(:any)
    }

    # case Integer.parse(room_version) do
    #   {version_num, ""} when version_num in 1..10 -> Map.put(schema, "creator", &Schema.user_id/1)
    #   _ -> schema
    # end
  end

  # TODO: validate localpart grammar
  defp room_localpart(localpart) do
    Schema.room_alias("##{localpart}:#{RadioBeam.server_name()}")
  end

  defp optional(type), do: [type, :optional]
end
