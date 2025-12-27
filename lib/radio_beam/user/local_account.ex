defmodule RadioBeam.User.LocalAccount do
  @moduledoc """
  Domain struct for a user's account on a local homeserver.
  """

  defstruct ~w|user_id pwd_hash registered_at|a
  @type t() :: %__MODULE__{}

  @max_user_id_size_bytes 255

  def new(user_id, password) do
    case validate_user_id(user_id) ++ validate_password(password) do
      [] -> {:ok, %__MODULE__{user_id: user_id, pwd_hash: hash(password), registered_at: DateTime.utc_now()}}
      [_ | _] = errors -> {:error, errors}
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
