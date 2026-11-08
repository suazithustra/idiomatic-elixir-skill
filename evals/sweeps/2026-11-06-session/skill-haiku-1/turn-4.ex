defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300
  @max_future_seconds 60

  @spec verify(binary(), String.t(), binary() | [binary()], integer()) ::
          {:ok, binary()} | {:error, atom()}
  def verify(body, header, secrets, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(body, secrets, timestamp, signature),
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

  # During rotation, the sender may still sign with the previous secret, so a
  # match against any listed secret is enough.
  defp check_signature(body, secrets, timestamp, signature) do
    matches? =
      Enum.any?(List.wrap(secrets), fn secret ->
        same_signature?(compute(body, secret, timestamp), signature)
      end)

    if matches? do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(timestamp, now) do
    if now - timestamp > @max_age_seconds or timestamp - now > @max_future_seconds do
      {:error, :expired}
    else
      :ok
    end
  end

  # :crypto.hash_equals/2 raises on binaries of different sizes, so the
  # size check comes first. The size itself is not secret: HMAC-SHA256 is
  # always 32 bytes.
  defp same_signature?(expected, signature) do
    byte_size(expected) == byte_size(signature) and :crypto.hash_equals(expected, signature)
  end

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
