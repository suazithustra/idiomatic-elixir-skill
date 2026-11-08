defmodule Webhooks.Signature do
  @moduledoc """
  Signs and verifies webhook request bodies with HMAC-SHA256 (keyed hash message authentication code, SHA-256 variant).

  A header value has the form `t=<unix seconds>,v1=<64 lowercase hex characters>`.
  The signature is the HMAC of `"<t>.<body>"` under the shared secret.
  """

  @max_age_seconds 300

  @doc """
  Verifies a signature header against the raw request body.

  Returns `{:ok, body}` when the signature matches and was made at most
  300 seconds before `now`. Otherwise returns `{:error, reason}`, where
  `reason` is `:malformed_header`, `:expired` or `:bad_signature`.

  `now` is the current Unix time in seconds.
  """
  @spec verify(binary(), binary(), binary(), integer()) ::
          {:ok, binary()} | {:error, :malformed_header | :expired | :bad_signature}
  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(header) and is_binary(secret) and is_integer(now) do
    with {:ok, timestamp, signature} <- parse_header(header),
         :ok <- check_age(timestamp, now),
         :ok <- check_signature(body, timestamp, signature, secret) do
      {:ok, body}
    end
  end

  @doc """
  Builds a signature header value for `body`, signed at `now`.

  `now` is the Unix time in seconds. The result is accepted by `verify/4`
  with the same secret and a `now` within 300 seconds of this one.
  """
  @spec sign(binary(), binary(), integer()) :: binary()
  def sign(body, secret, now)
      when is_binary(body) and is_binary(secret) and is_integer(now) do
    timestamp = Integer.to_string(now)
    "t=#{timestamp},v1=#{digest(timestamp, body, secret)}"
  end

  defp parse_header(header) do
    case String.split(header, ",") do
      ["t=" <> timestamp, "v1=" <> signature] -> parse_fields(timestamp, signature)
      ["v1=" <> signature, "t=" <> timestamp] -> parse_fields(timestamp, signature)
      _other -> {:error, :malformed_header}
    end
  end

  defp parse_fields(timestamp, signature) do
    if String.match?(timestamp, ~r/\A\d+\z/) and String.match?(signature, ~r/\A[0-9a-f]{64}\z/) do
      {:ok, timestamp, signature}
    else
      {:error, :malformed_header}
    end
  end

  # A timestamp later than `now` is refused too. The sender's clock is not
  # trusted to be behind ours, so a future time cannot be "within 300 seconds
  # before now".
  defp check_age(timestamp, now) do
    age = now - String.to_integer(timestamp)

    if age >= 0 and age <= @max_age_seconds do
      :ok
    else
      {:error, :expired}
    end
  end

  defp check_signature(body, timestamp, signature, secret) do
    # Both values are 64 hex characters, so the sizes match and hash_equals/2
    # compares every byte.
    if :crypto.hash_equals(digest(timestamp, body, secret), signature) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp digest(timestamp, body, secret) do
    payload = "#{timestamp}.#{body}"
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)
  end
end
