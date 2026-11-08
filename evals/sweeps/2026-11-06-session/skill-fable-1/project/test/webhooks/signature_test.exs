defmodule Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Webhooks.Signature

  @secret "shared-secret"

  test "verify/4 accepts a header made by sign/3" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a changed body" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("other", header, @secret, 1000)
  end

  test "verify/4 rejects a signature that differs in its last byte" do
    assert "t=1000,v1=" <> hex = Signature.sign("payload", @secret, 1000)
    {prefix, last} = String.split_at(hex, -1)
    flipped = if last == "0", do: "1", else: "0"

    assert {:error, :bad_signature} =
             Signature.verify("payload", "t=1000,v1=#{prefix}#{flipped}", @secret, 1000)
  end

  test "verify/4 rejects a signature shorter than an HMAC-SHA256 digest" do
    assert {:error, :bad_signature} = Signature.verify("payload", "t=1000,v1=abcd", @secret, 1000)
  end

  test "verify/4 accepts a header signed with the old secret during a rotation" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, ["new-secret", @secret], 1000)
  end

  test "verify/4 accepts a header signed with the new secret during a rotation" do
    header = Signature.sign("payload", "new-secret", 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, ["new-secret", @secret], 1000)
  end

  test "verify/4 rejects a header that matches none of the secrets" do
    header = Signature.sign("payload", "retired-secret", 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", header, ["new-secret", @secret], 1000)
  end

  test "verify/4 rejects every header when the list of secrets is empty" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, [], 1000)
  end

  test "verify/4 accepts a header with two signatures when the second one matches" do
    header = two_signature_header("payload", "new-secret", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 accepts a header with two signatures when the first one matches" do
    header = two_signature_header("payload", @secret, "new-secret", 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a header with two signatures when neither matches" do
    header = two_signature_header("payload", "retired-secret", "new-secret", 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a header whose second signature is not valid hex" do
    header = Signature.sign("payload", @secret, 1000) <> ",v1=zz"

    assert {:error, :malformed_header} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a header with a timestamp but no signature" do
    assert {:error, :malformed_header} = Signature.verify("payload", "t=1000", @secret, 1000)
  end

  test "verify/4 accepts a signature made exactly 300 seconds before now" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1300)
  end

  test "verify/4 rejects a signature made more than 300 seconds before now as expired" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1301)
  end

  test "verify/4 accepts a signature made exactly 60 seconds after now" do
    header = Signature.sign("payload", @secret, 1060)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a signature made more than 60 seconds after now as expired" do
    header = Signature.sign("payload", @secret, 1061)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 reports a bad signature on an expired request before reporting expiry" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("other", header, @secret, 1301)
  end

  test "verify/4 reports a missing header when the request carried none" do
    assert {:error, :missing_header} = Signature.verify("payload", nil, @secret, 1000)
  end

  test "verify/4 rejects a header it cannot parse" do
    assert {:error, :malformed_header} = Signature.verify("payload", "nonsense", @secret, 1000)
  end

  defp two_signature_header(body, first_secret, second_secret, now) do
    [_timestamp, second_signature] = String.split(Signature.sign(body, second_secret, now), ",")
    Signature.sign(body, first_secret, now) <> "," <> second_signature
  end
end
