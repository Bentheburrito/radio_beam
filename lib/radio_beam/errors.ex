defmodule RadioBeam.Errors do
  @moduledoc """
  Error helpers
  """

  @typedoc "A standard error response."
  @type t() :: %{required(:errcode) => String.t(), required(:error) => String.t()}

  def std_errors do
    ~w(forbidden unknown_token missing_token bad_json not_json not_found limit_exceeded unrecognized unknown)a
  end

  def forbidden(message \\ "You do not have sufficient access to this resource"),
    do: std_error_res("M_FORBIDDEN", message)

  def unknown_token(message \\ "The access/refresh token is not known. Please re-authenticate", soft_logout? \\ false),
    do: "M_UNKNOWN_TOKEN" |> std_error_res(message) |> Map.put(:soft_logout, soft_logout?)

  def missing_token(message \\ "Please provide an access token"), do: std_error_res("M_MISSING_TOKEN", message)

  def bad_json(message \\ "Params were missing from your request"), do: std_error_res("M_BAD_JSON", message)

  def not_json(message \\ "Bad JSON payload"), do: std_error_res("M_NOT_JSON", message)

  def not_found(message \\ "Resource not found"), do: std_error_res("M_NOT_FOUND", message)

  def limit_exceeded(
        retry_after_ms \\ nil,
        message \\ "You have been making too many requests. Please wait before trying again"
      )

  def limit_exceeded(nil, message),
    do: std_error_res("M_LIMIT_EXCEEDED", message)

  def limit_exceeded(retry_after_ms, message) when is_integer(retry_after_ms) and retry_after_ms > 0,
    do: "M_LIMIT_EXCEEDED" |> std_error_res(message) |> Map.put(:retry_after_ms, retry_after_ms)

  def unrecognized(message \\ "This homeserver does not implement that endpoint for the given HTTP method"),
    do: std_error_res("M_UNRECOGNIZED", message)

  def unknown(message \\ "An unknown error has occurred"), do: std_error_res("M_UNKNOWN", message)

  def endpoint_error(errcode, error) when is_atom(errcode) do
    errcode = errcode |> to_string() |> String.upcase()
    endpoint_error("M_" <> errcode, error)
  end

  def endpoint_error(errcode, error) when is_binary(errcode) and is_binary(error) do
    std_error_res(errcode, error)
  end

  @spec std_error_res(String.t(), String.t()) :: t()
  defp std_error_res(errcode, error) do
    %{
      errcode: errcode,
      error: error
    }
  end
end
