defmodule RadioBeam.RateLimit do
  @moduledoc """
  Manages rate limits for all RadioBeam resources.

  This module limits requests based on policy of several tiers, checked in the
  following order:

  1. Global, per-endpoint limits
  1. Global, per-user limits
  1. Per-user, per-endpoint limits
  1. Per-user, per-device limits
  1. IP limits

  Based on this policy, every request's `key` includes an endpoint (path), a
  user ID + device ID (if the Authorization header was present), and an
  IP address.
  """
  use Hammer, backend: :ets

  import Kernel, except: [/: 2]

  defstruct ~w|global_endpoint user_endpoint user_device ip|a

  @doc """
  Define a new `limit`, `scale` pair to give to a rate limit. Read as "`limit`
  requests per `scale`ms".

  For exsample: `15 / :timer.hours(1)` = "15 requests per hour"

  You will need to "unimport" `Kernel./` to use this as an infix operator:

  ```elixir
  import Kernel, except: [/: 2]
  import #{__MODULE__}, only: [/: 2]
  ```
  """
  def limit / scale, do: %{limit: limit, scale: scale}

  @global_user_rate_limit %{limit: 100, scale: :timer.minutes(1)}

  def new!(global_endpoint, user_endpoint, user_device, ip) do
    %__MODULE__{global_endpoint: global_endpoint, user_endpoint: user_endpoint, user_device: user_device, ip: ip}
  end

  def check(endpoint, :not_authenticated, ip_address, %__MODULE__{} = rl) do
    with {:allow, _count} <- hit(endpoint, rl.global_endpoint.scale, rl.global_endpoint.limit) do
      hit(ip_address, rl.ip.scale, rl.ip.limit)
    end
  end

  def check(endpoint, {user_id, device_id}, ip_address, %__MODULE__{} = rl) do
    with {:allow, _count} <- hit(endpoint, rl.global_endpoint.scale, rl.global_endpoint.limit),
         {:allow, _count} <- hit(user_id, @global_user_rate_limit.scale, @global_user_rate_limit.limit),
         {:allow, _count} <- hit({user_id, endpoint}, rl.user_endpoint.scale, rl.user_endpoint.limit),
         {:allow, _count} <- hit({user_id, device_id}, rl.user_device.scale, rl.user_device.limit) do
      hit(ip_address, rl.ip.scale, rl.ip.limit)
    end
  end
end
