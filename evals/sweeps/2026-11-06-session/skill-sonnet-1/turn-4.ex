defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300
  @max_clock_skew_seconds 60

  @doc """
  Verifies `header` against `body`.

  `secret` is one secret or a list of secrets; the signature is accepted when it
  matches any of them, which lets a secret be rotated without rejecting requests
  signed with the old one.
  """
  @spec verify(binary(), String.t(), binary() | [binary()], integer()) ::
          {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(signature, body, List.wrap(secret), timestamp),
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

  defp check_signature(signature, body, secrets, timestamp) do
    signed_by_any? =
      Enum.any?(secrets, fn secret -> matches?(signature, compute(body, secret, timestamp)) end)

    if signed_by_any? do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  # :crypto.hash_equals/2 raises on binaries of different sizes. The size of an
  # HMAC is public, so a length mismatch can be rejected without a constant-time compare.
  defp matches?(signature, expected) when byte_size(signature) == byte_size(expected) do
    :crypto.hash_equals(signature, expected)
  end

  defp matches?(_signature, _expected), do: false

  defp check_age(timestamp, now) do
    age = now - timestamp

    if age > @max_age_seconds or -age > @max_clock_skew_seconds do
      {:error, :expired}
    else
      :ok
    end
  end

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
