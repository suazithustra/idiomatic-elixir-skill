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

  test "verify/4 rejects a signature of the right length made with another secret" do
    header = Signature.sign("payload", "other-secret", 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects a truncated signature without raising" do
    "t=1000,v1=" <> hex = Signature.sign("payload", @secret, 1000)
    header = "t=1000,v1=" <> binary_part(hex, 0, 32)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 rejects an empty signature without raising" do
    assert {:error, :bad_signature} = Signature.verify("payload", "t=1000,v1=", @secret, 1000)
  end

  test "verify/4 accepts a signature exactly 300 seconds old" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1300)
  end

  test "verify/4 returns :expired for a signature older than 300 seconds" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1301)
  end

  test "verify/4 accepts a signature made 60 seconds in the future" do
    header = Signature.sign("payload", @secret, 1060)

    assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 returns :expired for a signature made more than 60 seconds in the future" do
    header = Signature.sign("payload", @secret, 1061)

    assert {:error, :expired} = Signature.verify("payload", header, @secret, 1000)
  end

  test "verify/4 returns :bad_signature, not :expired, for a forged old signature" do
    header = Signature.sign("payload", "other-secret", 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 5000)
  end

  test "verify/4 accepts a signature made with the second secret in a list" do
    header = Signature.sign("payload", "old-secret", 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, [@secret, "old-secret"], 1000)
  end

  test "verify/4 accepts a signature made with the only secret in a list" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:ok, "payload"} = Signature.verify("payload", header, [@secret], 1000)
  end

  test "verify/4 returns :bad_signature when no secret in the list matches" do
    header = Signature.sign("payload", "third-secret", 1000)

    assert {:error, :bad_signature} =
             Signature.verify("payload", header, [@secret, "old-secret"], 1000)
  end

  test "verify/4 returns :bad_signature for an empty list of secrets" do
    header = Signature.sign("payload", @secret, 1000)

    assert {:error, :bad_signature} = Signature.verify("payload", header, [], 1000)
  end

  describe "verify/4 with several signatures in the header" do
    setup do
      "t=1000," <> old = Signature.sign("payload", "old-secret", 1000)
      "t=1000," <> current = Signature.sign("payload", @secret, 1000)
      "t=1000," <> other = Signature.sign("payload", "other-secret", 1000)

      %{old: old, current: current, other: other}
    end

    test "accepts the header when the first signature matches", %{current: current, other: other} do
      header = "t=1000,#{current},#{other}"

      assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
    end

    test "accepts the header when only the last signature matches", %{
      current: current,
      other: other
    } do
      header = "t=1000,#{other},#{current}"

      assert {:ok, "payload"} = Signature.verify("payload", header, @secret, 1000)
    end

    test "accepts the header when each secret in a list matches a different signature", %{
      old: old,
      current: current
    } do
      header = "t=1000,#{old},#{current}"

      assert {:ok, "payload"} = Signature.verify("payload", header, [@secret, "old-secret"], 1000)
    end

    test "returns :bad_signature when no signature matches", %{old: old, other: other} do
      header = "t=1000,#{old},#{other}"

      assert {:error, :bad_signature} = Signature.verify("payload", header, @secret, 1000)
    end

    test "returns :malformed_header when one signature is not valid hex", %{current: current} do
      header = "t=1000,#{current},v1=zz"

      assert {:error, :malformed_header} = Signature.verify("payload", header, @secret, 1000)
    end

    test "returns :malformed_header when a part is not a v1 signature", %{current: current} do
      header = "t=1000,#{current},v0=abcd"

      assert {:error, :malformed_header} = Signature.verify("payload", header, @secret, 1000)
    end

    test "returns :malformed_header when the header has no signature" do
      assert {:error, :malformed_header} = Signature.verify("payload", "t=1000", @secret, 1000)
    end
  end

  test "verify/4 returns :missing_header for a nil header" do
    assert {:error, :missing_header} = Signature.verify("payload", nil, @secret, 1000)
  end

  test "verify/4 returns :malformed_header, not :missing_header, for an empty header" do
    assert {:error, :malformed_header} = Signature.verify("payload", "", @secret, 1000)
  end

  test "verify/4 rejects a header it cannot parse" do
    assert {:error, :malformed_header} = Signature.verify("payload", "nonsense", @secret, 1000)
  end
end
