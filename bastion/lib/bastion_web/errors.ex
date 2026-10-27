defmodule BastionWeb.Errors do
  use Gettext, backend: BastionWeb.Gettext

  @spec message(atom()) :: String.t()
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
  def message(:folder_not_found), do: gettext("Folder not found")
  def message(:invalid_csr), do: gettext("The device sent an invalid certificate request")

  def message(:subject_mismatch),
    do: gettext("The certificate request does not match the device ID")

  def message(_), do: gettext("Something went wrong, try again")
end
