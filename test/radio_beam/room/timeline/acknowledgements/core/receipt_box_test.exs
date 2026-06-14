defmodule RadioBeam.Room.Timeline.Acknowledgements.Core.ReceiptBoxTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline.Acknowledgements.Core.ReceiptBox

  setup do
    %{user_id: user_id} = Fixtures.create_account()
    %{user_id: other_id} = Fixtures.create_account()

    {:ok, room_id} = Room.create(user_id)

    {:ok, _} = Room.invite(room_id, user_id, other_id)
    {:ok, _} = Room.join(room_id, other_id)

    {:ok, event_id} = Room.send_text_message(room_id, user_id, "Helloooooooo")
    %{box: ReceiptBox.new!(), room_id: room_id, user_id: user_id, other_id: other_id, event_id: event_id}
  end

  describe "put/4-6" do
    test "puts new receipts, overwriting existing {user_id, receipt_type, thread_id} tuples", %{
      box: box,
      user_id: user_id,
      other_id: other_id,
      event_id: event_id
    } do
      assert %ReceiptBox{} = box = ReceiptBox.put(box, user_id, event_id, "m.read")
      assert 1 = ReceiptBox.count(box)

      assert %ReceiptBox{} = box = ReceiptBox.put(box, user_id, event_id, "m.read.private")
      assert 2 = ReceiptBox.count(box)

      assert %ReceiptBox{} = box = ReceiptBox.put(box, other_id, event_id, "m.read.private")
      assert 3 = ReceiptBox.count(box)

      assert %ReceiptBox{} = box = ReceiptBox.put(box, other_id, event_id, "m.read.private")
      assert 3 = ReceiptBox.count(box)

      assert %ReceiptBox{} = box = ReceiptBox.put(box, other_id, event_id, "m.read.private", :main)
      assert 4 = ReceiptBox.count(box)

      assert %ReceiptBox{} = box = ReceiptBox.put(box, other_id, event_id, "m.read.private", :main)
      assert 4 = ReceiptBox.count(box)
    end
  end

  describe "get_all/4-6" do
    test "returns all receipts as an m.receipt event's content", %{
      box: box,
      room_id: room_id,
      user_id: user_id,
      other_id: other_id,
      event_id: event_id
    } do
      {:ok, event_id2} = Room.send_text_message(room_id, other_id, "sup")

      assert %{} = empty = ReceiptBox.get_all(box)
      assert 0 = map_size(empty)

      box = ReceiptBox.put(box, user_id, event_id, "m.read")
      assert %{^event_id => %{"m.read" => %{^user_id => %{ts: _} = payload}}} = ReceiptBox.get_all(box)
      refute is_map_key(payload, :thread_id)

      box = ReceiptBox.put(box, user_id, event_id2, "m.read", :main)

      assert %{
               ^event_id => %{"m.read" => %{^user_id => %{ts: _} = payload}},
               ^event_id2 => %{"m.read" => %{^user_id => %{ts: _, thread_id: "main"}}}
             } = ReceiptBox.get_all(box)

      refute is_map_key(payload, :thread_id)

      box = ReceiptBox.put(box, other_id, event_id2, "m.read")

      assert %{
               ^event_id => %{"m.read" => %{^user_id => %{ts: _} = payload}},
               ^event_id2 => %{"m.read" => %{^user_id => %{ts: _, thread_id: "main"}, ^other_id => %{ts: _} = payload2}}
             } = ReceiptBox.get_all(box)

      refute is_map_key(payload, :thread_id)
      refute is_map_key(payload2, :thread_id)
    end

    test "returns all receipts since the given timestamp as an m.receipt event's content", %{
      box: box,
      room_id: room_id,
      user_id: user_id,
      other_id: other_id,
      event_id: event_id
    } do
      {:ok, event_id2} = Room.send_text_message(room_id, other_id, "yo")

      now = RadioBeam.Time.now()

      box =
        box
        |> ReceiptBox.put(user_id, event_id, "m.read", :unthreaded, now - 3)
        |> ReceiptBox.put(user_id, event_id2, "m.read", :main, now - 2)
        |> ReceiptBox.put(other_id, event_id2, "m.read", :unthreaded, now - 1)

      assert %{
               ^event_id2 => %{"m.read" => %{^user_id => %{ts: _, thread_id: "main"}, ^other_id => %{ts: _} = payload2}}
             } = content = ReceiptBox.get_all(box, now - 2)

      refute is_map_key(content, event_id)

      refute is_map_key(payload2, :thread_id)

      assert %{^event_id2 => %{"m.read" => %{^other_id => %{ts: _} = payload2}} = m_reads} =
               content = ReceiptBox.get_all(box, now - 1)

      refute is_map_key(content, event_id)
      refute is_map_key(m_reads, user_id)

      refute is_map_key(payload2, :thread_id)

      assert %{} = content = ReceiptBox.get_all(box, now)
      assert 0 = map_size(content)
    end
  end
end
