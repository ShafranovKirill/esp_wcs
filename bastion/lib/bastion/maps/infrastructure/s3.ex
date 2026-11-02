defmodule Bastion.Maps.Infrastructure.S3 do
  @moduledoc "Private, path-style S3 operations. Credentials never leave the server."

  def setup do
    config = config()

    with :ok <- validate(config) do
      case request(:head, config[:bucket], "", "", nil) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: 404}} ->
          case request(:put, config[:bucket], "", "", nil) do
            {:ok, %{status: status}} when status in [200, 201, 204] -> :ok
            result -> error(result)
          end

        result ->
          error(result)
      end
    end
  end

  def put(key, data, type) do
    config = config()

    with :ok <- validate(config) do
      case request(:put, config[:bucket], key, data, type) do
        {:ok, %{status: status}} when status in [200, 201, 204] ->
          {:ok, %{background: key, storage: "s3", bucket: config[:bucket]}}

        result ->
          error(result)
      end
    end
  end

  def get(bucket, key) do
    with :ok <- validate(config()) do
      case request(:get, bucket, key, "", nil) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :not_found}
        result -> error(result)
      end
    end
  end

  defp request(method, bucket, key, body, type) do
    config = config()

    path =
      Enum.map_join(
        [bucket | String.split(key, "/", trim: true)],
        "/",
        &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)
      )

    url = String.trim_trailing(config[:endpoint], "/") <> "/" <> path
    headers = if type, do: [{"content-type", type}], else: []

    Req.request(
      Keyword.merge(
        [
          method: method,
          url: url,
          body: body,
          headers: headers,
          aws_sigv4: [
            access_key_id: config[:access_key_id],
            secret_access_key: config[:secret_access_key],
            region: config[:region] || "us-east-1",
            service: :s3
          ],
          decode_body: false,
          redirect: false,
          retry: false,
          receive_timeout: 15_000,
          connect_options: [timeout: 5_000]
        ],
        Keyword.get(config, :request_options, [])
      )
    )
  end

  defp validate(config) do
    with endpoint when is_binary(endpoint) <- config[:endpoint],
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
         when scheme in ["http", "https"] and is_binary(host) <- URI.parse(endpoint),
         true <-
           Enum.all?(
             [:bucket, :access_key_id, :secret_access_key],
             &(is_binary(config[&1]) and config[&1] != "")
           ) do
      :ok
    else
      _ -> {:error, :storage_not_configured}
    end
  end

  defp error({:ok, %{status: status}}) when status in [401, 403], do: {:error, :storage_denied}
  defp error(_), do: {:error, :storage_unavailable}
  defp config, do: Application.get_env(:bastion, Bastion.Maps, []) |> Keyword.get(:s3, [])
end
