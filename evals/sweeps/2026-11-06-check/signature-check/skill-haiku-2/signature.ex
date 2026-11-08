defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook request bodies with HMAC-SHA256 (keyed hash
  message authentication code, SHA-256 variant).

  A header value has the form `t=<unix seconds>,v1=<lowercase hex HMAC>`.
  The HMAC is computed over `"<t>.<body>"` with the shared secret.
  """

  @max_age_seconds 300
  @signature_bytes 32

  @doc """
  Verifies a signature header against the raw request body.

  Returns `{:ok, body}` when the signature matches and was made at most
  300 seconds before `now`. Otherwise returns `{:error, reason}`, where
  `reason` is `:malformed_header`, `:bad_signature` or `:expired`.

  The signature is checked before the timestamp, so `:expired` is only
  returned for a signature that is authentic. A timestamp later than `now`
  is treated as `:expired`.
  """
  @spec verify(binary(), term(), binary(), integer()) ::
          {:ok, binary()} | {:error, :malformed_header | :bad_signature | :expired}
  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(secret) and is_integer(now) do
    with {:ok, timestamp, signature} <- parse_header(header) do
      check(body, timestamp, signature, secret, now)
    end
  end

  @doc """
  Builds a signature header value for `body`, signed at `now`.

  Use it to produce headers that `verify/4` accepts.
  """
  @spec sign(binary(), binary(), integer()) :: binary()
  def sign(body, secret, now) when is_binary(body) and is_binary(secret) and is_integer(now) do
    signature = Base.encode16(mac(now, body, secret), case: :lower)
    "t=#{now},v1=#{signature}"
  end

  defp parse_header(header) when is_binary(header) do
    with {:ok, fields} <- split_fields(header),
         {:ok, timestamp} <- single_field(fields, "t", &parse_timestamp/1),
         {:ok, signature} <- single_field(fields, "v1", &parse_signature/1) do
      {:ok, timestamp, signature}
    end
  end

  defp parse_header(_header), do: {:error, :malformed_header}

  defp split_fields(header) do
    fields = Enum.map(String.split(header, ","), &String.split(&1, "=", parts: 2))

    if Enum.all?(fields, &match?([_key, _value], &1)) do
      {:ok, fields}
    else
      {:error, :malformed_header}
    end
  end

  defp single_field(fields, key, parse) do
    case for([^key, value] <- fields, do: value) do
      [value] ->
        parse.(value)

      [] ->
        {:error, :malformed_header}

      [_first, _second | _rest] ->
        {:error, :malformed_header}
    end
  end

  defp parse_timestamp(value) do
    if Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value) do
      {:ok, String.to_integer(value)}
    else
      {:error, :malformed_header}
    end
  end

  defp parse_signature(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, signature} when byte_size(signature) == @signature_bytes ->
        {:ok, signature}

      _not_a_signature ->
        {:error, :malformed_header}
    end
  end

  defp check(body, timestamp, signature, secret, now) do
    if :crypto.hash_equals(mac(timestamp, body, secret), signature) do
      check_age(body, timestamp, now)
    else
      {:error, :bad_signature}
    end
  end

  defp check_age(body, timestamp, now) do
    age = now - timestamp

    if age in 0..@max_age_seconds do
      {:ok, body}
    else
      {:error, :expired}
    end
  end

  defp mac(timestamp, body, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}." <> body)
  end
end
