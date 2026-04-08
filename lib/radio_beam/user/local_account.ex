defmodule RadioBeam.User.LocalAccount do
  @moduledoc """
  Domain struct for a user's account on a local homeserver.
  """
  alias RadioBeam.User.LocalAccount.State

  @attrs ~w|user_id pwd_hash registered_at state_changes|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{}

  @max_user_id_size_bytes 255

  def new(user_id, password) do
    case validate_user_id(user_id) ++ validate_password(password) do
      [] ->
        {:ok,
         %__MODULE__{user_id: user_id, pwd_hash: hash(password), registered_at: DateTime.utc_now(), state_changes: []}}

      [_ | _] = errors ->
        {:error, errors}
    end
  end

  def lock(%__MODULE__{} = account, admin_id, state_opts \\ []), do: put_state(account, :locked, admin_id, state_opts)

  def suspend(%__MODULE__{} = account, admin_id, state_opts \\ []),
    do: put_state(account, :suspended, admin_id, state_opts)

  def remove_restrictions(%__MODULE__{} = account, admin_id, state_opts \\ []),
    do: put_state(account, :unrestricted, admin_id, state_opts)

  defp put_state(%__MODULE__{} = account, state_name, admin_id, state_opts) do
    update_in(account.state_changes, &[State.new!(state_name, admin_id, state_opts) | &1])
  end

  def locked?(%__MODULE__{} = account, at \\ DateTime.utc_now()) do
    case List.first(account.state_changes) do
      nil ->
        false

      %State{state_name: :locked, effective_until: :infinity} = state ->
        DateTime.compare(at, state.changed_at) in ~w|gt eq|a

      %State{state_name: :locked} = state ->
        DateTime.compare(at, state.changed_at) in ~w|gt eq|a and
          DateTime.compare(at, state.effective_until) in ~w|lt eq|a

      %State{} ->
        false
    end
  end

  def suspended?(%__MODULE__{} = account, at \\ DateTime.utc_now()) do
    case Enum.find(account.state_changes, &is_struct(&1, State)) do
      nil ->
        false

      %State{state_name: :suspended, effective_until: :infinity} = state ->
        DateTime.compare(at, state.changed_at) in ~w|gt eq|a

      %State{state_name: :suspended} = state ->
        DateTime.compare(at, state.changed_at) in ~w|gt eq|a and
          DateTime.compare(at, state.effective_until) in ~w|lt eq|a

      %State{} ->
        false
    end
  end

  defp validate_user_id(user_id) when not is_binary(user_id), do: [user_id: "must be a string"]

  defp validate_user_id(user_id) when byte_size(user_id) > @max_user_id_size_bytes,
    do: [user_id: "cannot be more than 255 bytes"]

  defp validate_user_id(user_id) do
    case String.split(user_id, ":") do
      ["@" <> localpart, _server_name] when localpart != "" -> validate_localpart(localpart)
      _invalid_format -> [user_id: "User IDs must be of the form @localpart:servername"]
    end
  end

  defp validate_localpart(localpart) do
    if Regex.match?(~r|^[a-z0-9\._=/+-]+$|, localpart) do
      []
    else
      [user_id: "localpart can only contain lowercase alphanumeric characters, or the symbols ._=-/+"]
    end
  end

  defp validate_password(password) do
    if strong_password?(password) do
      []
    else
      [pwd_hash: "password is too weak"]
    end
  end

  @doc "Checks if the password is strong"
  @spec strong_password?(String.t()) :: boolean()
  def strong_password?(password) do
    Regex.match?(~r/^(?=.*[A-Z])(?=.*[!@#$%^&*\(\)\-+=\{\[\}\]|\\:;"'<,>.?\/])(?=.*[0-9])(?=.*[a-z]).{8,}$/, password)
  end

  @hash_pwd_opts [t_cost: 3, m_cost: 12, parallelism: 1]
  defp hash(password) do
    Argon2.hash_pwd_salt(password, @hash_pwd_opts)
  end

  @doc """
  Pass-through to `Argon2.no_user_verify/1`, passing in RadioBeam's password
  hashing options. From `Argon2`'s docs:

  > Runs the password hash function, but always returns false.
  >
  > This function is intended to make it more difficult for any potential
  > attacker to find valid usernames by using timing attacks. This function
  > is only useful if it is used as part of a policy of hiding usernames.
  """
  def no_user_verify, do: Argon2.no_user_verify(@hash_pwd_opts)
end
