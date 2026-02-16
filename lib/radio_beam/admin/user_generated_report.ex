defmodule RadioBeam.Admin.UserGeneratedReport do
  @moduledoc """
  A user-submitted report for abusive or inappropriate content

  The `target` is either a user ID, room ID, or `{room_id, event_id}` tuple.
  """
  @attrs ~w|target reason submitted_by created_at|a
  @enforce_keys @attrs
  defstruct @attrs

  @type target() :: User.id() | Room.id() | {Room.id(), Room.event_id()}
  @type t() :: %__MODULE__{
          target: target(),
          submitted_by: User.id(),
          created_at: DateTime.t(),
          reason: String.t() | nil
        }

  @spec new(target(), User.id(), DateTime.t(), String.t() | nil) ::
          {:ok, t()} | {:error, :invalid_target_or_submitted_by}
  def new(target, submitted_by, created_at, reason \\ nil)

  def new(<<sigil::binary-1>> <> _ = target, "@" <> _ = submitted_by, created_at, reason) when sigil in ~w|! @| do
    {:ok, %__MODULE__{target: target, submitted_by: submitted_by, created_at: created_at, reason: reason}}
  end

  def new({"!" <> _ = _room_id, "$" <> _ = _event_id} = target, "@" <> _ = submitted_by, created_at, reason) do
    {:ok, %__MODULE__{target: target, submitted_by: submitted_by, created_at: created_at, reason: reason}}
  end

  def new(_target, _submitted_by, _created_at, _reason), do: {:error, :invalid_target_or_submitted_by}
end
