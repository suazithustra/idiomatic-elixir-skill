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

  test "verify/4 rejects a header it cannot parse" do
    assert {:error, :malformed_header} = Signature.verify("payload", "nonsense", @secret, 1000)
  end
end
