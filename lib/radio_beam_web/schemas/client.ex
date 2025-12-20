defmodule RadioBeamWeb.Schemas.Client do
  @moduledoc false

  import RadioBeamWeb.Schemas, only: [user_id: 1]

  alias Polyjuice.Util.Schema

  def send_to_device do
    %{"messages" => Schema.object_with_entries(&user_id/1, Schema.object_with_entries(:string, device_message()))}
  end

  defp device_message, do: %{}
end
