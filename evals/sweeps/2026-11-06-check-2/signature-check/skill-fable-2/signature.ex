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

  defp check_signature(body, secret, timestamp, signature) do
    expected = compute(body, secret, timestamp)

    if secure_equal?(expected, signature) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  # Rejecting a wrong length early leaks nothing: the MAC length is fixed and public.
  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp check_age(timestamp, now) when now - timestamp > @max_age_seconds, do: {:error, :expired}
  defp check_age(_timestamp, _now), do: :ok

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
