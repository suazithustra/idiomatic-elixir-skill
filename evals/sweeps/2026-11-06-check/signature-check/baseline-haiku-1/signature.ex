defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook requests.

  Header format: `t=<unix seconds>,v1=<lowercase hex HMAC-SHA256>`, where the
  HMAC is computed over `"<t>.<body>"` with the shared secret.
  """

  @tolerance_seconds 300

  @type reason :: :malformed_header | :expired | :bad_signature

  @doc """
  Verifies `header` against `body`.

  Returns `{:ok, body}` when a `v1` value matches and the timestamp `t` is
  at most #{@tolerance_seconds} seconds before `now`. Otherwise returns
  `{:error, reason}`. The signature is checked before the timestamp, so
  `:expired` is only reported for requests whose signature is authentic.
  """
  @spec verify(binary(), binary(), binary(), integer()) ::
          {:ok, binary()} | {:error, reason()}
  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(header) and is_binary(secret) and is_integer(now) do
    with {:ok, t, signatures} <- parse_header(header),
         :ok <- check_signature(body, secret, t, signatures),
         :ok <- check_age(t, now) do
      {:ok, body}
    end
  end

  def verify(_body, _header, _secret, _now), do: {:error, :malformed_header}

  @doc """
  Builds a header value for `body` signed at Unix time `now`.
  """
  @spec sign(binary(), binary(), integer()) :: binary()
  def sign(body, secret, now) do
    "t=#{now},v1=#{mac(body, secret, now)}"
  end

  defp mac(body, secret, t) do
    :crypto.mac(:hmac, :sha256, secret, "#{t}.#{body}")
    |> Base.encode16(case: :lower)
  end

  defp parse_header(header) do
    fields =
      for part <- String.split(header, ","),
          [key, value] <- [String.split(String.trim(part), "=", parts: 2)],
          do: {key, value}

    with [t_string | _] <- for({"t", value} <- fields, do: value),
         true <- Regex.match?(~r/\A\d+\z/, t_string),
         signatures when signatures != [] <- for({"v1", value} <- fields, do: value),
         true <- Enum.all?(signatures, &valid_hex?/1) do
      {:ok, String.to_integer(t_string), signatures}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp valid_hex?(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp check_signature(body, secret, t, signatures) do
    expected = mac(body, secret, t)

    if Enum.any?(signatures, &secure_compare(&1, expected)) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(t, now) do
    age = now - t

    if age >= 0 and age <= @tolerance_seconds do
      :ok
    else
      {:error, :expired}
    end
  end

  # Compares every byte pair before deciding, so the time taken does not
  # depend on where the first mismatch occurs.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    diff =
      Enum.reduce(Enum.zip(:binary.bin_to_list(a), :binary.bin_to_list(b)), 0, fn {x, y}, acc ->
        Bitwise.bor(acc, Bitwise.bxor(x, y))
      end)

    diff == 0
  end

  defp secure_compare(_a, _b), do: false
end
