defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300

  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(signature, compute(body, secret, timestamp)),
         :ok <- check_age(timestamp, now) do
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

  # :crypto.hash_equals/2 raises on binaries of different sizes. The size of an
  # HMAC is public, so a length mismatch can be rejected without a constant-time compare.
  defp check_signature(signature, expected) when byte_size(signature) == byte_size(expected) do
    if :crypto.hash_equals(signature, expected) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_signature(_signature, _expected), do: {:error, :bad_signature}

  defp check_age(timestamp, now) when now - timestamp > @max_age_seconds, do: {:error, :expired}
  defp check_age(_timestamp, _now), do: :ok

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
