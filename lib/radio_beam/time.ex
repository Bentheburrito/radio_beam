defmodule RadioBeam.Time do
  @moduledoc "Time utils"

  if Mix.env() == :test do
    # bit hacky, but room v12 IDs are hash-based, so a user creating 2+ rooms
    # at the same `origin_server_ts` with no other content differences gives
    # the same room ID. Only really a problem in tests, so just use
    # microseconds instead of forcing all timestamps to be monotonic...
    def now, do: System.os_time(:microsecond)
  else
    def now, do: System.os_time(:millisecond)
  end
end
