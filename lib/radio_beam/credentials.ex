defmodule RadioBeam.Credentials do
  @moduledoc """
  Context module pertaining to anything and everything user-auth related from
  the spec.
  """
  @doc "Checks if the password is strong, according to the critera in `weak_password_message/0"
  @spec strong_password?(String.t()) :: boolean()
  def strong_password?(password) do
    Regex.match?(~r/^(?=.*[A-Z])(?=.*[!@#$%^&*\(\)\-+=\{\[\}\]|\\:;"'<,>.?\/])(?=.*[0-9])(?=.*[a-z]).{8,}$/, password)
  end

  def hash_pwd(password) do
    Argon2.hash_pwd_salt(password,
      t_cost: 3,
      m_cost: 12,
      parallelism: 1
    )
  end

  def weak_password_message do
    """
    Please include a password with at least:

    - 1 uppercase letter
    - 1 lowercase letter
    - 1 special character of the following: !@#$%^&*()_-+={[}]|\:;"'<,>.?/
    - 1 number
    - 8 characters total
    """
  end
end
