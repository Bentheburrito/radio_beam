defmodule RadioBeam.Repo do
  use Ecto.Repo,
    otp_app: :radio_beam,
    adapter: Ecto.Adapters.Postgres
end
