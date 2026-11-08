defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook payloads.

  Header format: `t=<unix seconds>,v1=<lowercase hex HMAC-SHA256 of "<t>.<body>">`.
  """

  @tolerance_seconds 300

  @type reason :: :malformed_header | :expired | :bad_signature

  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) when is_binary(body) and is_binary(secret) and is_integer(now) do
    "t=#{now},v1=#{compute(body, secret, now)}"
  end

  @spec verify(binary(), binary(), binary(), integer()) :: {:ok, binary()} | {:error, reason()}
  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(secret) and is_integer(now) do
    with {:ok, t, sig} <- parse(header),
         :ok <- check_age(t, now),
         :ok <- check_signature(body, secret, t, sig) do
      {:ok, body}
    end
  end

  def verify(_body, _header, _secret, _now), do: {:error, :malformed_header}

  defp compute(body, secret, t) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{t}." <> body)
    |> Base.encode16(case: :lower)
  end

  defp parse(header) when is_binary(header) do
    pairs = String.split(header, ",")

    with [t_str] <- values(pairs, "t"),
         [sig] <- values(pairs, "v1"),
         {t, ""} <- Integer.parse(t_str),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sig) do
      {:ok, t, sig}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse(_), do: {:error, :malformed_header}

  defp values(pairs, key) do
    for pair <- pairs, [^key, value] <- [String.split(pair, "=", parts: 2)], do: value
  end

  # A timestamp in the future is rejected too; only 0..300 seconds old is accepted.
  defp check_age(t, now) when now - t > @tolerance_seconds or t > now, do: {:error, :expired}
  defp check_age(_t, _now), do: :ok

  defp check_signature(body, secret, t, sig) do
    if :crypto.hash_equals(compute(body, secret, t), sig) do
      :ok
    else
      {:error, :bad_signature}
    end
  end
end
