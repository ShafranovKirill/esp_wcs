defmodule Bastion.PKI.FakeHostDiscovery do
  @moduledoc "Имя и адреса машины для тестов центра сертификации"
  use Boundary, top_level?: true, check: [in: false, out: false]

  @key {__MODULE__, :hosts}

  def set(hostname, addresses), do: :persistent_term.put(@key, {hostname, addresses})

  def hostname, do: elem(get(), 0)
  def addresses, do: elem(get(), 1)

  defp get, do: :persistent_term.get(@key, {"testhost", [{192, 168, 1, 10}]})
end
