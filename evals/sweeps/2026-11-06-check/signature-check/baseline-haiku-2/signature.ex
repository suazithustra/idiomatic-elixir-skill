defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook requests.

  Header format: `t=<unix seconds>,v1=<lowercase hex HMAC-SHA256>`.
  The HMAC (keyed hash) is computed over `"<t>.<body>"` with the shared secret.
  """

  @tolerance_seconds 300

  @type reason :: :malformed_header | :expired | :bad_signature

  @doc "Builds a header value for `body`, signed at Unix time `now`."
  @spec sign(binary(), binary(), integer()) :: binary()
  def sign(body, secret, now)
      when is_binary(body) and is_binary(secret) and is_integer(now) do
    timestamp = Integer.to_string(now)
    "t=#{timestamp},v1=#{hmac_hex(secret, timestamp, body)}"
  end

  @doc """
  Verifies `header` against the raw `body`.

  The signature is checked before the timestamp, so `:expired` is only
  returned for requests whose signature is genuine.
  """
  @spec verify(binary(), term(), binary(), integer()) ::
          {:ok, binary()} | {:error, reason()}
  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(secret) and is_integer(now) do
    with {:ok, timestamp, signatures} <- parse_header(header),
         :ok <- check_signature(body, timestamp, signatures, secret),
         :ok <- check_age(timestamp, now) do
      {:ok, body}
    end
  end

  defp parse_header(header) when is_binary(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(fn part -> part |> String.trim() |> String.split("=", parts: 2) end)

    timestamps = for ["t", value] <- pairs, do: value
    signatures = for ["v1", value] <- pairs, do: value

    with [timestamp] <- timestamps,
         true <- Regex.match?(~r/\A\d+\z/, timestamp),
         [_ | _] <- signatures,
         true <- Enum.all?(signatures, &Regex.match?(~r/\A[0-9a-f]{64}\z/, &1)) do
      {:ok, timestamp, signatures}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse_header(_), do: {:error, :malformed_header}

  defp check_signature(body, timestamp, signatures, secret) do
    expected = hmac_hex(secret, timestamp, body)

    # Reduce instead of Enum.any?/2 so every candidate is compared, not just
    # up to the first match.
    matched =
      Enum.reduce(signatures, false, fn signature, acc ->
        secure_equal?(signature, expected) or acc
      end)

    if matched, do: :ok, else: {:error, :bad_signature}
  end

  defp check_age(timestamp, now) do
    age = now - String.to_integer(timestamp)

    # Future timestamps (age < 0) are rejected too.
    if age >= 0 and age <= @tolerance_seconds, do: :ok, else: {:error, :expired}
  end

  defp hmac_hex(secret, timestamp, body) do
    :crypto.mac(:hmac, :sha256, secret, [timestamp, ".", body])
    |> Base.encode16(case: :lower)
  end

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_a, _b), do: false
end
