defmodule RadioBeamWeb.Schemas.Relations do
  @moduledoc false

  alias Polyjuice.Util.Schema
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeamWeb.Schemas.Filter

  def get_children do
    %{
      "dir" => [Schema.enum(%{"f" => :forward, "b" => :backward}, &String.downcase/1), default: :backward],
      "from" => optional(&pagination_token/1),
      "limit" => [&Filter.limit/1, default: RadioBeam.max_timeline_events()],
      "to" => optional(&pagination_token/1),
      "recurse" => [:boolean, default: false]
    }
  end

  # TODO these are in schemas/sync.ex too, extract into helper fxns
  defp pagination_token(token), do: PaginationToken.parse(token)
  defp optional(type), do: [type, :optional]
end
