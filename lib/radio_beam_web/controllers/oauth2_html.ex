defmodule RadioBeamWeb.OAuth2HTML do
  use RadioBeamWeb, :html

  embed_templates "oauth2_html/*"

  def scope_title({:device_id, _device_id}) do
    "Register a new device"
  end

  def scope_title({:cs_api, _access}) do
    "Send requests on your behalf"
  end

  def scope_description({:device_id, device_id}) do
    """
    Register a new device (ID #{device_id}). Note: for this device to
    access your old E2EE messages, you will need to verify the device after
    logging in.
    """
  end

  def scope_description({:cs_api, [:read, :write]}) do
    """
    Be able to read and modify your account data, including messages and
    metadata.
    """
  end
end
