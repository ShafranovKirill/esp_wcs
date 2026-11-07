defmodule Bastion.Hotspot.Infrastructure.NetworkManager do
  @profile "esp-wcs-bastion"

  def change(action) do
    with executable when is_binary(executable) <- System.find_executable("nmcli"),
         {_, 0} <-
           System.cmd(
             executable,
             ["--wait", "20", "connection", operation(action), "id", @profile],
             stderr_to_stdout: true
           ) do
      :ok
    else
      _ -> {:error, :network_manager}
    end
  rescue
    _ -> {:error, :network_manager}
  end

  defp operation(:start), do: "up"
  defp operation(:stop), do: "down"
end
