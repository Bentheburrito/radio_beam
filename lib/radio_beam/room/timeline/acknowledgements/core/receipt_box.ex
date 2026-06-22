defmodule RadioBeam.Room.Timeline.Acknowledgements.Core.ReceiptBox do
  @moduledoc """
  Tracks user-submitted event read receipts.

  should this be a View.Core mod? think I need to track events "ahead" of each
  other - though maybe we can build off of View.Core.Timeline
  """

  alias RadioBeam.Room
  alias RadioBeam.Time
  alias RadioBeam.User

  # "m.read" | "m.read.private"
  @typep receipt_type() :: String.t()
  @typep thread_id() :: :main | :unthreaded | Room.event_id()
  @typep user_key() :: {User.id(), receipt_type(), thread_id()}

  defstruct receipt_map: %{}

  @opaque t() :: %__MODULE__{
            receipt_map: %{user_key() => %{optional(:thread_id) => thread_id(), required(:ts) => non_neg_integer()}}
          }

  @valid_receipt_types ~w|m.read m.read.private|

  def new!, do: %__MODULE__{receipt_map: %{}}

  def put(%__MODULE__{} = box, user_id, event_id, type, thread_id \\ :unthreaded, timestamp \\ Time.now())
      when type in @valid_receipt_types do
    put_in(box.receipt_map[{user_id, type, thread_id}], %{event_id: event_id, timestamp: timestamp})
  end

  def count(%__MODULE__{} = box), do: map_size(box.receipt_map)

  def get_all(%__MODULE__{} = box, for_user_id, since_ts \\ :all) do
    box.receipt_map
    |> filter_since(since_ts)
    |> reject_others_private_receipts(for_user_id)
    |> Enum.reduce(%{}, fn {{user_id, receipt_type, thread_id}, receipt}, m_receipt_content ->
      payload = payload(thread_id, receipt.timestamp)

      Map.update(
        m_receipt_content,
        receipt.event_id,
        %{receipt_type => %{user_id => payload}},
        &Map.update(&1, receipt_type, %{user_id => payload}, fn user_map -> Map.put(user_map, user_id, payload) end)
      )
    end)
  end

  defp filter_since(receipts, :all), do: receipts

  defp filter_since(receipts, timestamp),
    do: Stream.filter(receipts, fn {_k, receipt} -> receipt.timestamp >= timestamp end)

  defp reject_others_private_receipts(receipts, getting_user_id) do
    Stream.reject(receipts, fn {{user_id, receipt_type, _thread_id}, _receipt} ->
      user_id != getting_user_id and receipt_type == "m.read.private"
    end)
  end

  defp payload(:unthreaded, timestamp), do: %{ts: timestamp}
  defp payload(:main, timestamp), do: %{thread_id: "main", ts: timestamp}
  defp payload("$" <> _ = event_id, timestamp), do: %{thread_id: event_id, ts: timestamp}
end
