defmodule RadioBeamWeb.Schemas.DeviceKeys do
  @moduledoc false

  import RadioBeamWeb.Schemas, only: [user_id: 1]

  alias Polyjuice.Util.Schema

  def upload do
    %{
      "one_time_keys" => optional(Schema.object_with_entries(:string, Schema.any_of([:string, key_object()]))),
      "fallback_keys" => optional(Schema.object_with_entries(:string, Schema.any_of([:string, fallback_key_object()])))
    }
  end

  def claim do
    %{
      "one_time_keys" => Schema.object_with_entries(&user_id/1, Schema.object_with_entries(:string, :string))
    }
  end

  defp key_object do
    %{
      "key" => :string,
      "signatures" => Schema.object_with_entries(&user_id/1, Schema.object_with_entries(:string, :string))
    }
  end

  defp fallback_key_object do
    Map.put(key_object(), "fallback", [:boolean, default: false])
  end

  defp optional(type), do: [type, :optional]
end
