defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300
  @max_skew_seconds 60

  @doc """
  Verifies `header` against `body` and returns `{:ok, body}` for an authentic request.

  Returns `{:error, :malformed_header}` when the header does not parse,
  `{:error, :bad_signature}` when the signature does not match, and
  `{:error, :expired}` when an authentic signature was made more than
  #{@max_age_seconds} seconds before `now` or more than #{@max_skew_seconds}
  seconds after it. `now` is a Unix time in seconds.
  """
  @spec verify(binary(), String.t(), binary(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- check_signature(signature, compute(body, secret, timestamp)),
         :ok <- check_timestamp(timestamp, now) do
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

  defp check_timestamp(timestamp, now) when now - timestamp > @max_age_seconds do
    {:error, :expired}
  end

  defp check_timestamp(timestamp, now) when timestamp - now > @max_skew_seconds do
    {:error, :expired}
  end

  defp check_timestamp(_timestamp, _now), do: :ok

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
