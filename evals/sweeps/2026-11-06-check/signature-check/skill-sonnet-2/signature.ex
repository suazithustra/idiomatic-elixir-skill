defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook request bodies.

  A header value looks like `t=1727000000,v1=<hex>`, where `t` is the Unix time
  of signing and `v1` is the lowercase hex HMAC-SHA256 of `"<t>.<body>"`.
  """

  @tolerance_seconds 300

  @doc """
  Builds a signature header value for `body`, signed at Unix time `now`.

  ## Examples

      iex> header = Webhooks.Signature.sign("{}", "secret", 1_727_000_000)
      iex> String.starts_with?(header, "t=1727000000,v1=")
      true
  """
  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) do
    "t=#{now},v1=#{Base.encode16(mac(body, secret, now), case: :lower)}"
  end

  @doc """
  Verifies `header` against `body`, with `now` as the current Unix time.

  Returns `{:ok, body}` when the signature matches and was made at most 300
  seconds before `now`. Otherwise returns `{:error, reason}` with `reason` one
  of `:malformed_header`, `:expired` or `:bad_signature`.

  ## Examples

      iex> header = Webhooks.Signature.sign("{}", "secret", 1_727_000_000)
      iex> Webhooks.Signature.verify("{}", header, "secret", 1_727_000_100)
      {:ok, "{}"}
      iex> Webhooks.Signature.verify("{}", header, "secret", 1_727_000_301)
      {:error, :expired}
      iex> Webhooks.Signature.verify("{}", header, "other", 1_727_000_100)
      {:error, :bad_signature}
      iex> Webhooks.Signature.verify("{}", "garbage", "secret", 1_727_000_100)
      {:error, :malformed_header}
  """
  @spec verify(binary(), binary(), binary(), integer()) ::
          {:ok, binary()} | {:error, :malformed_header | :expired | :bad_signature}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse_header(header),
         :ok <- check_signature(body, secret, timestamp, signature),
         :ok <- check_age(timestamp, now) do
      {:ok, body}
    end
  end

  defp parse_header(header) when is_binary(header) do
    fields =
      for pair <- String.split(header, ","),
          [key, value] <- [String.split(pair, "=", parts: 2)],
          into: %{},
          do: {key, value}

    with %{"t" => raw_timestamp, "v1" => raw_signature} <- fields,
         {:ok, timestamp} <- parse_timestamp(raw_timestamp),
         {:ok, signature} <- decode_signature(raw_signature) do
      {:ok, timestamp, signature}
    else
      fields when is_map(fields) -> {:error, :malformed_header}
      {:error, :malformed_header} = error -> error
    end
  end

  defp parse_header(_header), do: {:error, :malformed_header}

  defp parse_timestamp(raw_timestamp) do
    case Integer.parse(raw_timestamp) do
      {timestamp, ""} ->
        {:ok, timestamp}

      {_timestamp, _rest} ->
        {:error, :malformed_header}

      :error ->
        {:error, :malformed_header}
    end
  end

  defp decode_signature(raw_signature) do
    case Base.decode16(raw_signature, case: :lower) do
      {:ok, signature} when byte_size(signature) == 32 ->
        {:ok, signature}

      {:ok, _wrong_size} ->
        {:error, :malformed_header}

      :error ->
        {:error, :malformed_header}
    end
  end

  defp check_signature(body, secret, timestamp, signature) do
    if :crypto.hash_equals(mac(body, secret, timestamp), signature) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(timestamp, now) when now - timestamp <= @tolerance_seconds, do: :ok
  defp check_age(_timestamp, _now), do: {:error, :expired}

  defp mac(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
