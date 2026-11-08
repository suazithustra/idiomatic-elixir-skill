defmodule Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Webhooks.Signature

  @secret "shared-secret"

  test "verify/4 accepts a header made by sign/3" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 accepts a signature made exactly 300 seconds ago" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1300)
  end

  test "verify/4 returns :expired for a signature made more than 300 seconds ago" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1301)
  end

  test "verify/4 accepts a signature timestamped exactly 60 seconds ahead" do
    header = Signature.sign("payload", @secret, 1060)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 returns :expired for a signature timestamped more than 60 seconds ahead" do
    header = Signature.sign("payload", @secret, 1061)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 reports a bad signature before an expired one" do
    header = Signature.sign("other", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 5000)
  end

  test "verify/4 accepts a signature made with any secret in the list" do
    header = Signature.sign("payload", "previous-secret", 1000)

    assert {:ok, "payload"} =
             Signature.verify("payload", header, [@secret, "previous-secret"], 1000)
  end

  test "verify/4 rejects a signature that matches none of the listed secrets" do
    header = Signature.sign("payload", "retired-secret", 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", header, [@secret, "previous-secret"], 1000)
  end

  test "verify/4 accepts a header when a later v1 signature matches" do
    "t=1000," <> good_sig = Signature.sign("payload", @secret, 1000)
    header = "t=1000,v1=" <> String.duplicate("00", 32) <> "," <> good_sig

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 accepts a header when an earlier v1 signature matches" do
    "t=1000," <> good_sig = Signature.sign("payload", @secret, 1000)
    header = "t=1000," <> good_sig <> ",v1=" <> String.duplicate("00", 32)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a header whose v1 signatures match none of the secrets" do
    header = "t=1000,v1=" <> String.duplicate("00", 32) <> ",v1=" <> String.duplicate("11", 32)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a header with a timestamp and no signature" do
    assert {:error, :malformed_header} = Signature.verify("payload", "t=1000", @secret, 1000)
  end

  test "verify/4 rejects a changed body" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("other", header, @secret, 1000)
  end

  test "verify/4 rejects a signature of the right size with the wrong value" do
    header = "t=1000,v1=" <> String.duplicate("00", 32)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a signature shorter than an HMAC-SHA256 digest" do
    header = "t=1000,v1=" <> String.duplicate("00", 31)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 returns :missing_header when the request has no header" do
    assert {:error, :missing_header} = Signature.verify("payload", nil, @secret, 1000)
  end

  test "verify/4 rejects a header it cannot parse" do
    assert {:error, :malformed_header} = Signature.verify("payload", "nonsense", @secret, 1000)
  end
end
