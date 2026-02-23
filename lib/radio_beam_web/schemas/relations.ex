defmodule RadioBeamWeb.Schemas.Relations do
  @moduledoc false

  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.Filter

  def get_children do
    %{
      "dir" => [
        Schema.enum(%{"f" => :chronological, "b" => :reverse_chronological}, &String.downcase/1),
        default: :reverse_chronological
      ],
      "from" => optional(&RadioBeam.Sync.parse_batch_token/1),
      "limit" => [&Filter.limit/1, default: RadioBeam.max_timeline_events()],
      "to" => optional(&RadioBeam.Sync.parse_batch_token/1),
      "recurse" => [:boolean, default: false]
    }
  end

  defp optional(type), do: [type, :optional]
end
