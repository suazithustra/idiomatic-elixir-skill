defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, _now) do
    with {:ok, timestamp, signature} <- parse(header) do
      expected = compute(body, secret, timestamp)

      if secure_equal?(expected, signature) do
        {:ok, body}
      else
        {:error, :bad_signature}
      end
    end
  end

  # Constant-time comparison so a mismatch does not leak how many leading
  # bytes were correct. `:crypto.hash_equals/2` raises on unequal lengths, and
  # the expected length (32 bytes for HMAC-SHA256) is not secret, so a
  # wrong-length signature can be rejected immediately.
  defp secure_equal?(expected, signature)
       when byte_size(expected) == byte_size(signature) do
    :crypto.hash_equals(expected, signature)
  end

  defp secure_equal?(_expected, _signature), do: false

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

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
