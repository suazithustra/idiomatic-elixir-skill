defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300

  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(body, secret, timestamp, signature),
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

  # The signature is checked before the age, so a timestamp from a request
  # that was not signed by us is never reported as expired.
  defp check_signature(body, secret, timestamp, signature) do
    expected = compute(body, secret, timestamp)

    # :crypto.hash_equals/2 raises when the lengths differ, and the header
    # controls the length of the signature, so compare lengths first.
    matches? =
      byte_size(expected) == byte_size(signature) and
        :crypto.hash_equals(expected, signature)

    if matches? do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(timestamp, now) do
    if now - timestamp > @max_age_seconds do
      {:error, :expired}
    else
      :ok
    end
  end

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
