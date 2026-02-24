defmodule RadioBeamWeb.Schemas.Room do
  @moduledoc false

  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.Filter
  alias RadioBeamWeb.Schemas.InstantMessaging

  def invite do
    %{"user_id" => &Schema.user_id/1, "reason" => optional(:string)}
  end

  def leave, do: %{"reason" => optional(:string)}

  def join do
    # TOIMPL: third_party_signed
    %{"third_party_signed" => optional(:any), "reason" => optional(:string)}
  end

  def create do
    available_room_versions = RadioBeam.supported_room_versions()
    default_room_version = RadioBeam.default_room_version()

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

  def get_nearest_event do
    %{
      "dir" => Schema.enum(%{"f" => :forward, "b" => :backward}, &String.downcase/1),
      "ts" => &stringed_int/1
    }
  end

  def get_event_context do
    %{
      "filter" => optional(Schema.any_of([Filter.room_event_filter(), &Filter.json_room_event_filter/1])),
      "limit" => [&Filter.limit/1, default: RadioBeam.max_timeline_events()]
    }
  end

  def put_typing, do: %{"typing" => :boolean, "timeout" => optional(:integer)}

  defp stringed_int(integer) when is_integer(integer), do: {:ok, integer}

  defp stringed_int(str_int) when is_binary(str_int) do
    case Integer.parse(str_int) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid}
    end
  end

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
