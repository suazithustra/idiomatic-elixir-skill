defmodule Webhooks.Signature do
  @moduledoc """
  Verifies the signature header on incoming webhook requests.
  """

  @max_age_seconds 300
  @max_skew_seconds 60

  @doc """
  Verifies `header` against `body` and returns `{:ok, body}` for an authentic request.

  `secrets` is one shared secret or a list of them; during a rotation, pass the old
  and the new secret and the signature is accepted when it matches any of them. The
  header may likewise carry several signatures, `t=...,v1=<hex>,v1=<hex>`, and is
  accepted when any of them matches any secret.

  Returns `{:error, :missing_header}` when `header` is `nil` because the request
  carried none, `{:error, :malformed_header}` when the header does not parse,
  `{:error, :bad_signature}` when no signature matches any secret, and
  `{:error, :expired}` when an authentic signature was made more than
  #{@max_age_seconds} seconds before `now` or more than #{@max_skew_seconds}
  seconds after it. `now` is a Unix time in seconds.
  """
  @spec verify(binary(), String.t() | nil, binary() | [binary()], integer()) ::
          {:ok, binary()} | {:error, atom()}
  def verify(body, header, secrets, now) do
    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- check_signatures(body, List.wrap(secrets), timestamp, signatures),
         :ok <- check_timestamp(timestamp, now) do
      {:ok, body}
    end
  end

  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, now) do
    "t=#{now},v1=#{Base.encode16(compute(body, secret, now), case: :lower)}"
  end

  defp parse(nil), do: {:error, :missing_header}

  defp parse("t=" <> rest) do
    [timestamp | signatures] = String.split(rest, ",")

    with {:ok, timestamp} <- parse_timestamp(timestamp),
         {:ok, signatures} <- parse_signatures(signatures) do
      {:ok, timestamp, signatures}
    end
  end

  defp parse(_header), do: {:error, :malformed_header}

  defp parse_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {timestamp, ""} -> {:ok, timestamp}
      {_timestamp, _rest} -> {:error, :malformed_header}
      :error -> {:error, :malformed_header}
    end
  end

  defp parse_signatures([]), do: {:error, :malformed_header}
  defp parse_signatures(signatures), do: parse_signatures(signatures, [])

  defp parse_signatures([], decoded), do: {:ok, Enum.reverse(decoded)}

  defp parse_signatures([signature | rest], decoded) do
    with {:ok, bytes} <- parse_signature(signature) do
      parse_signatures(rest, [bytes | decoded])
    end
  end

  defp parse_signature("v1=" <> hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed_header}
    end
  end

  defp parse_signature(_signature), do: {:error, :malformed_header}

  defp check_signatures(body, secrets, timestamp, signatures) do
    expected = Enum.map(secrets, &compute(body, &1, timestamp))

    if Enum.any?(signatures, &matches_any?(&1, expected)) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp matches_any?(signature, expected) do
    Enum.any?(expected, &secure_equal?(signature, &1))
  end

  # :crypto.hash_equals/2 raises on binaries of different lengths, so the length
  # check comes first. The length of a valid signature is public, so comparing it
  # in variable time leaks nothing.
  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

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
