defmodule Bastion.Maps.Infrastructure.Storage do
  alias Bastion.Maps.Infrastructure.S3

  def put(relative, image) do
    case Application.get_env(:bastion, Bastion.Maps, [])[:storage] || "local" do
      "s3" ->
        S3.put("maps/" <> relative, image.data, image.type)

      "local" ->
        path = Path.join(data_dir(), relative)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, image.data) do
          {:ok, %{background: relative, storage: "local", bucket: nil}}
        else
          _ -> {:error, :storage_unavailable}
        end
    end
  end

  def location(%{storage: "s3", bucket: bucket, background: key}), do: {:s3, bucket, key}
  def location(%{background: path}), do: Path.join(data_dir(), path)

  def read({:s3, bucket, key}) do
    with {:ok, data} <- S3.get(bucket, key), do: {:ok, {:data, data}}
  end

  def read(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, {:file, path}}, else: {:error, :not_found}
  end

  defp data_dir do
    config = Application.get_env(:bastion, Bastion.PKI, [])
    Path.join(Keyword.get(config, :data_dir, "data"), "maps")
  end
end
