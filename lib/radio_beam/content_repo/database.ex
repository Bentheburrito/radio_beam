defmodule RadioBeam.ContentRepo.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend for content repository
  upload metadata.
  """
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.MatrixContentURI

  @type user_upload_counts() :: %{reserved: non_neg_integer(), uploaded: non_neg_integer()}

  @callback upsert_upload(Upload.t()) :: :ok | {:error, term()}
  @callback fetch_upload(MatrixContentURI.t()) :: {:ok, Upload.t()} | {:error, :not_found}

  @doc """
  Runs the given arity-1 callback with the number of uploaded files under the
  given `uploader_user_id`.

  Note: the database backend MUST ensure the callback is run atomically. If the
  callback is not atomic, two concurrent file uploads initiated by a user will
  race, potentially letting them upload files exceeding their quota.
  """
  @callback with_user_total_uploaded_bytes(uploader_user_id :: RadioBeam.User.id(), (non_neg_integer() -> term())) ::
              term()

  @doc """
  Runs the given arity-1 callback with a map describing the given
  `uploader_user_id`'s total uploaded file sizes in bytes.

  The map takes the form of `t:user_upload_counts`.

  Note: the database backend MUST ensure the callback is run atomically. If the
  callback is not atomic, two concurrent file uploads initiated by a user will
  race, potentially letting them upload files exceeding their quota.
  """
  @callback with_user_upload_counts(uploader_user_id :: RadioBeam.User.id(), (user_upload_counts() -> term())) :: term()

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.ContentRepo.Database, :backend])
  defdelegate upsert_upload(upload), to: @database_backend
  defdelegate fetch_upload(mxc), to: @database_backend
  defdelegate with_user_total_uploaded_bytes(uploader_user_id, callback), to: @database_backend
  defdelegate with_user_upload_counts(uploader_user_id, callback), to: @database_backend
end
