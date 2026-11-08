defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  # Maximum accepted age of a signature, in seconds.
  @max_age 300

  # Maximum accepted distance into the future, in seconds. Allows for clock
  # skew between sender and receiver; anything beyond it is treated as expired.
  @max_skew 60

  @typedoc """
  A single shared secret, or a list of them. Passing a list lets the receiver
  accept signatures made under the old or the new secret during rotation.
  """
  @type secrets :: binary() | [binary()]

  @spec verify(binary(), String.t(), secrets(), integer()) :: {:ok, binary()} | {:error, atom()}
  def verify(body, header, secrets, now) do
    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- check_signatures(body, List.wrap(secrets), timestamp, signatures),
         :ok <- check_age(timestamp, now) do
      {:ok, body}
    end
  end

  # The signature is checked before the age so an unauthenticated caller
  # cannot learn which timestamps the server would still accept. A header may
  # carry several `v1=` signatures during rotation; any one of them matching
  # under any accepted secret is enough.
  defp check_signatures(body, secrets, timestamp, signatures) do
    matched? =
      Enum.any?(secrets, fn secret ->
        expected = compute(body, secret, timestamp)
        Enum.any?(signatures, &secure_equal?(expected, &1))
      end)

    if matched?, do: :ok, else: {:error, :bad_signature}
  end

  defp check_age(timestamp, now) when now - timestamp > @max_age, do: {:error, :expired}
  defp check_age(timestamp, now) when timestamp - now > @max_skew, do: {:error, :expired}
  defp check_age(_timestamp, _now), do: :ok

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

  # Accepts "t=<int>,v1=<hex>" with one or more "v1=" entries. Every entry
  # must be well-formed; a header with no "v1=" entry is malformed.
  defp parse("t=" <> rest) do
    with [timestamp | [_ | _] = parts] <- String.split(rest, ","),
         {timestamp, ""} <- Integer.parse(timestamp),
         {:ok, signatures} <- parse_signatures(parts) do
      {:ok, timestamp, signatures}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse(_header), do: {:error, :malformed_header}

  defp parse_signatures(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      "v1=" <> hex, {:ok, acc} ->
        case Base.decode16(hex, case: :lower) do
          {:ok, signature} -> {:cont, {:ok, [signature | acc]}}
          :error -> {:halt, :error}
        end

      _part, _acc ->
        {:halt, :error}
    end)
  end

  defp compute(body, secret, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
  end
end
