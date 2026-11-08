defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300

  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_age(timestamp, now),
         :ok <- check_signature(body, secret, timestamp, signature) do
      {:ok, body}
    end
  end

  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) do
    "t=#{now},v1=#{Base.encode16(compute(body, secret, now), case: :lower)}"
  end

  defp parse("t=" <> rest) do
    with [timestamp, "v1=" <> hex] <- String.split(rest, ",", parts: 2),
         {timestamp, ""} <- Integer.parse(timestamp),
         {:ok, signature} <- Base.decode16(hex, case: :lower) do
      {:ok, timestamp, signature}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse(_header), do: {:error, :malformed_header}

  defp check_age(timestamp, now) when now - timestamp > @max_age_seconds, do: {:error, :expired}
  defp check_age(_timestamp, _now), do: :ok

  defp check_signature(body, secret, timestamp, signature) do
    expected = compute(body, secret, timestamp)

    # hash_equals/2 compares in constant time but raises when the sizes differ.
    # The expected size is a public constant, so checking it first leaks nothing.
    if byte_size(signature) == byte_size(expected) and :crypto.hash_equals(signature, expected) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
