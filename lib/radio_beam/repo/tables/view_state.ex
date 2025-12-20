defmodule RadioBeam.Repo.Tables.ViewState do
  @moduledoc false
  use Memento.Table,
    attributes: [:key, :value],
    type: :set

  def dump!(view_state), do: view_state
  def load!(view_state), do: view_state
end
