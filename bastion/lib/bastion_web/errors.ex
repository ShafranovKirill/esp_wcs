defmodule BastionWeb.Errors do
  use Gettext, backend: BastionWeb.Gettext

  @spec message(atom() | String.t()) :: String.t()
  def message(:not_found), do: gettext("Device not found — it may have been deleted")
  def message(:not_pending), do: gettext("The request has already been processed")
  def message(:not_approved), do: gettext("Only an approved device can be revoked")
  def message(:not_revoked), do: gettext("Revoke the device before deleting it")
  def message(:name_taken), do: gettext("This name is already taken")
  def message(:blank), do: gettext("Enter a name")

  def message(:too_long),
    do:
      gettext("The name is too long (max %{max} characters)",
        max: Bastion.Fleet.name_max_length()
      )

  def message(:invalid), do: gettext("The name contains invalid characters")

  def message(:code_changed),
    do: gettext("The device sent a new request with a different code — compare the code again")

  def message(:fleet_full),
    do: gettext("Device limit reached (%{max})", max: Bastion.Fleet.max_devices())

  def message(:folder_not_found), do: gettext("Folder not found")
  def message(:invalid_csr), do: gettext("The device sent an invalid certificate request")

  def message(:subject_mismatch),
    do: gettext("The certificate request does not match the device ID")

  def message(:offline), do: gettext("The device is offline")
  def message(:timeout), do: gettext("The device did not respond in time")
  def message(:rate_limited), do: gettext("Too many commands, wait a second")
  def message(:not_owner), do: gettext("The console is controlled by another tab")
  def message(:invalid_line), do: gettext("Invalid port settings")
  def message("invalid_args"), do: gettext("The device rejected the parameters")
  def message("unknown_op"), do: gettext("The device firmware does not support this command")

  def message(_), do: gettext("Something went wrong, try again")
end
