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

  test "verify/4 accepts a signature exactly 300 seconds old" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1300)
  end

  test "verify/4 rejects a signature more than 300 seconds old" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1301)
  end

  test "verify/4 accepts a signature exactly 60 seconds in the future" do
    header = Signature.sign("payload", @secret, 1060)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a signature more than 60 seconds in the future" do
    header = Signature.sign("payload", @secret, 1061)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 reports a bad signature before reporting expiry" do
    header = Signature.sign("payload", "other-secret", 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 5000)
  end

  test "verify/4 accepts a list of secrets when the signature matches any of them" do
    old_header = Signature.sign("payload", "old-secret", 1000)
    new_header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} =
             Signature.verify("payload", old_header, ["old-secret", @secret], 1000)

    assert {:ok, "payload"} =
             Signature.verify("payload", new_header, ["old-secret", @secret], 1000)
  end

  test "verify/4 rejects a signature that matches none of the listed secrets" do
    header = Signature.sign("payload", "retired-secret", 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", header, ["old-secret", @secret], 1000)
  end

  test "verify/4 rejects every signature when the secret list is empty" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, [], 1000)
  end

  test "verify/4 still checks expiry when a listed secret matches" do
    header = Signature.sign("payload", "old-secret", 1000)

    assert {:error, :expired} =
             Signature.verify("payload", header, ["old-secret", @secret], 1301)
  end

  test "verify/4 accepts a header carrying several v1 signatures when any matches" do
    "t=1000," <> old_sig = Signature.sign("payload", "old-secret", 1000)
    "t=1000," <> new_sig = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} =
             Signature.verify("payload", "t=1000,#{old_sig},#{new_sig}", @secret, 1000)

    assert {:ok, "payload"} =
             Signature.verify("payload", "t=1000,#{new_sig},#{old_sig}", @secret, 1000)
  end

  test "verify/4 rejects a header whose v1 signatures all fail" do
    "t=1000," <> a = Signature.sign("payload", "retired-a", 1000)
    "t=1000," <> b = Signature.sign("payload", "retired-b", 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", "t=1000,#{a},#{b}", @secret, 1000)
  end

  test "verify/4 matches several v1 signatures against several secrets" do
    "t=1000," <> old_sig = Signature.sign("payload", "old-secret", 1000)
    "t=1000," <> other = Signature.sign("payload", "unrelated", 1000)

    assert {:ok, "payload"} =
             Signature.verify(
               "payload",
               "t=1000,#{other},#{old_sig}",
               ["old-secret", @secret],
               1000
             )
  end

  test "verify/4 treats a header with a malformed extra v1 entry as malformed" do
    "t=1000," <> good = Signature.sign("payload", @secret, 1000)

    assert {:error, :malformed_header} =
             Signature.verify("payload", "t=1000,#{good},v1=zz", @secret, 1000)

    assert {:error, :malformed_header} =
             Signature.verify("payload", "t=1000,#{good},v2=00", @secret, 1000)
  end

  test "verify/4 treats a header with no v1 entry as malformed" do
    assert {:error, :malformed_header} = Signature.verify("payload", "t=1000", @secret, 1000)
  end

  test "verify/4 rejects a signature made with a different secret" do
    header = Signature.sign("payload", "other-secret", 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a same-length signature that differs in its last byte" do
    "t=1000,v1=" <> hex = Signature.sign("payload", @secret, 1000)
    {prefix, last} = String.split_at(hex, -1)
    flipped = if last == "0", do: "1", else: "0"

    assert {:error, :bad_signature} =
             Signature.verify("payload", "t=1000,v1=#{prefix}#{flipped}", @secret, 1000)
  end

  test "verify/4 rejects a signature of the wrong length without raising" do
    "t=1000,v1=" <> hex = Signature.sign("payload", @secret, 1000)
    short = binary_part(hex, 0, 16)

    assert {:error, :bad_signature} =
             Signature.verify("payload", "t=1000,v1=#{short}", @secret, 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", "t=1000,v1=#{hex}abcd", @secret, 1000)
  end

  test "verify/4 reports a missing header when it is nil" do
    assert {:error, :missing_header} = Signature.verify("payload", nil, @secret, 1000)
    assert {:error, :missing_header} = Signature.verify("payload", nil, [@secret], 1000)
  end

  test "verify/4 rejects a header it cannot parse" do
    assert {:error, :malformed_header} = Signature.verify("payload", "nonsense", @secret, 1000)
  end
end
