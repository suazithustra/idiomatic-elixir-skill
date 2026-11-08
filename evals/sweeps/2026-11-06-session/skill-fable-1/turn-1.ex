defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, _now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(signature, compute(body, secret, timestamp)) do
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

  # :crypto.hash_equals/2 raises on binaries of different lengths, so the length
  # check comes first. The length of a valid signature is public, so comparing it
  # in variable time leaks nothing.
  defp check_signature(signature, expected) when byte_size(signature) == byte_size(expected) do
    if :crypto.hash_equals(signature, expected) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_signature(_signature, _expected), do: {:error, :bad_signature}

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
