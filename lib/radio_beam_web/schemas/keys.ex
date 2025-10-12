defmodule RadioBeamWeb.Schemas.Keys do
  @moduledoc false

  import RadioBeamWeb.Schemas, only: [user_id: 1]

  alias Polyjuice.Util.Schema
  alias RadioBeam.Room.Events.PaginationToken

  def changes, do: %{"from" => &pagination_token/1}

  defp pagination_token(token), do: PaginationToken.parse(token)

  def upload do
    %{
      "device_keys" => optional(device_keys()),
      "one_time_keys" => optional(Schema.object_with_entries(:string, Schema.any_of([:string, key_object()]))),
      "fallback_keys" => optional(Schema.object_with_entries(:string, Schema.any_of([:string, fallback_key_object()])))
    }
  end

  def upload_cross_signing do
    %{
      "master_key" => optional(cross_signing_key()),
      "self_signing_key" => optional(cross_signing_key()),
      "user_signing_key" => optional(cross_signing_key())
    }
  end

  def upload_signatures do
    Schema.object_with_entries(
      &user_id/1,
      Schema.object_with_entries(:string, Schema.any_of([cross_signing_key(), device_keys()]))
    )
  end

  def claim do
    %{
      "one_time_keys" => Schema.object_with_entries(&user_id/1, Schema.object_with_entries(:string, :string))
    }
  end

  def query do
    %{"device_keys" => Schema.object_with_entries(&user_id/1, Schema.array_of(:string))}
  end

  defp device_keys do
    %{
      "algorithms" => Schema.array_of(:string),
      "device_id" => :string,
      "keys" => Schema.object_with_entries(:string, :string),
      "signatures" => signatures(),
      "user_id" => &user_id/1
    }
  end

  defp key_object do
    %{
      "key" => :string,
      "signatures" => signatures()
    }
  end

  defp cross_signing_key do
    %{
      "keys" => Schema.object_with_entries(:string, :string),
      "signatures" => optional(signatures()),
      "usage" => Schema.array_of(:string),
      "user_id" => &user_id/1
    }
  end

  defp signatures, do: Schema.object_with_entries(&user_id/1, Schema.object_with_entries(:string, :string))

  defp fallback_key_object do
    Map.put(key_object(), "fallback", [:boolean, default: false])
  end

  defp optional(type), do: [type, :optional]
end
