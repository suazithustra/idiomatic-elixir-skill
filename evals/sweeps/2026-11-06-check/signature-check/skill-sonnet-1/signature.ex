defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook requests.

  A header looks like `t=<unix seconds>,v1=<hex>`, where the hex is the
  lowercase HMAC-SHA256 (hash-based message authentication code) of
  `"<t>.<body>"` under the shared secret.
  """

  @tolerance_seconds 300

  @doc """
  Builds a header value for `body`, signed at Unix time `now`.

  ## Examples

      iex> header = Webhooks.Signature.sign("{}", "secret", 1_727_000_000)
      iex> String.starts_with?(header, "t=1727000000,v1=")
      true
  """
  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) do
    signature = Base.encode16(compute_mac(body, secret, now), case: :lower)
    "t=#{now},v1=#{signature}"
  end

  @doc """
  Verifies `header` against `body`, where `now` is the current Unix time in seconds.

  Returns `{:ok, body}` when the signature matches and was made at most 300
  seconds before `now`.

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
  @spec verify(binary(), term(), binary(), integer()) ::
          {:ok, binary()} | {:error, :malformed_header | :expired | :bad_signature}
  def verify(body, header, secret, now) do
    with {:ok, signed_at, signature} <- parse_header(header),
         :ok <- check_signature(body, secret, signed_at, signature),
         :ok <- check_age(signed_at, now) do
      {:ok, body}
    end
  end

  defp parse_header(header) when is_binary(header) do
    case String.split(header, ",") do
      ["t=" <> raw_time, "v1=" <> raw_signature] ->
        with {:ok, signed_at} <- parse_time(raw_time),
             {:ok, signature} <- decode_signature(raw_signature) do
          {:ok, signed_at, signature}
        end

      _fields ->
        {:error, :malformed_header}
    end
  end

  defp parse_header(_header), do: {:error, :malformed_header}

  defp parse_time(raw_time) do
    case Integer.parse(raw_time) do
      {signed_at, ""} ->
        {:ok, signed_at}

      _no_integer ->
        {:error, :malformed_header}
    end
  end

  defp decode_signature(raw_signature) do
    case Base.decode16(raw_signature, case: :lower) do
      {:ok, signature} ->
        {:ok, signature}

      :error ->
        {:error, :malformed_header}
    end
  end

  defp check_signature(body, secret, signed_at, signature) do
    expected = compute_mac(body, secret, signed_at)

    if byte_size(signature) == byte_size(expected) and
         :crypto.hash_equals(signature, expected) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(signed_at, now) when now - signed_at <= @tolerance_seconds, do: :ok
  defp check_age(_signed_at, _now), do: {:error, :expired}

  defp compute_mac(body, secret, signed_at) do
    :crypto.mac(:hmac, :sha256, secret, "#{signed_at}.#{body}")
  end
end
