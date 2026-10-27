defmodule Bastion.PKI.Infrastructure.FileStore do
  @spec read(Path.t(), String.t()) :: {:ok, binary()} | {:error, :enoent} | {:error, File.posix()}
  def read(dir, name), do: File.read(Path.join(dir, name))

  @spec write!(Path.t(), String.t(), iodata(), :secret | :public) :: :ok
  def write!(dir, name, data, kind) do
    ensure_dir!(dir)
    path = Path.join(dir, name)
    tmp = path <> ".tmp"

    File.write!(tmp, data)
    File.chmod!(tmp, mode(kind))
    File.rename!(tmp, path)
  end

  @spec ensure_dir!(Path.t()) :: :ok
  def ensure_dir!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
  end

  defp mode(:secret), do: 0o600
  defp mode(:public), do: 0o644
end
