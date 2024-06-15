defmodule RadioBeam do
  @moduledoc """
  RadioBeam keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  def server_name, do: Application.fetch_env!(:radio_beam, :server_name)

  def env, do: Application.fetch_env!(:radio_beam, :env)
end
