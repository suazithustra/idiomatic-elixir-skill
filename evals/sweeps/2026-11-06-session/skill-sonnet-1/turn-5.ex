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

  The header may carry several `v1=` signatures, as in `t=1727000000,v1=<hex>,v1=<hex>`;
  it is accepted when any of them matches any secret.
  """
  @spec verify(binary(), String.t(), binary() | [binary()], integer()) ::
          {:ok, binary()} | {:error, atom()}
  def verify(body, header, secret, now) do
    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- check_signature(signatures, body, List.wrap(secret), timestamp),
         :ok <- check_age(timestamp, now) do
      {:ok, body}
    end
  end

  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) do
    "t=#{now},v1=#{Base.encode16(compute(body, secret, now), case: :lower)}"
  end

  defp parse("t=" <> rest) do
    [timestamp | signature_parts] = String.split(rest, ",")

    with {:ok, timestamp} <- parse_timestamp(timestamp),
         {:ok, signatures} <- parse_signatures(signature_parts, []) do
      {:ok, timestamp, signatures}
    end
  end

  defp parse(_header), do: {:error, :malformed_header}

  defp parse_timestamp(text) do
    case Integer.parse(text) do
      {timestamp, ""} ->
        {:ok, timestamp}

      {_timestamp, _rest} ->
        {:error, :malformed_header}

      :error ->
        {:error, :malformed_header}
    end
  end

  defp parse_signatures([], []), do: {:error, :malformed_header}
  defp parse_signatures([], signatures), do: {:ok, Enum.reverse(signatures)}

  defp parse_signatures(["v1=" <> hex | rest], signatures) do
    case Base.decode16(hex, case: :lower) do
      {:ok, signature} ->
        parse_signatures(rest, [signature | signatures])

      :error ->
        {:error, :malformed_header}
    end
  end

  defp parse_signatures([_part | _rest], _signatures), do: {:error, :malformed_header}

  defp check_signature(signatures, body, secrets, timestamp) do
    expected_macs = Enum.map(secrets, &compute(body, &1, timestamp))

    signed? =
      Enum.any?(signatures, fn signature -> Enum.any?(expected_macs, &matches?(signature, &1)) end)

    if signed? do
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
