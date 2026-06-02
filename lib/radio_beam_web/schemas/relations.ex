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

  def get_threads do
    %{
      "from" => [Schema.any_of([Schema.enum(%{"latest" => :latest, "end" => :end}), :string]), default: :latest],
      "include" => [Schema.enum(%{"all" => :all, "participated" => :participated}), default: :all],
      "limit" => [&Filter.limit(&1, 50), default: 25]
    }
  end

  defp optional(type), do: [type, :optional]
end
