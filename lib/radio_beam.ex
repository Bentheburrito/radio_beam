defmodule RadioBeam do
  @moduledoc """
  RadioBeam keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  def versions do
    %{
      unstable_versions: %{},
      versions: ["v1.9"]
    }
  end
end
