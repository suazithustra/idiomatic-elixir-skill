defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  describe "add_item/3" do
    test "adds a new item" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert cart.items == %{"APPLE" => 2}
    end

    test "increases the quantity of an item already in the cart" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("APPLE", 3)

      assert cart.items == %{"APPLE" => 5}
    end
  end

  describe "remove_item/3" do
    test "removes some units of an item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly its quantity" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when removing more units than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged when the SKU is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts a known code, ignoring case and surrounding whitespace" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "  save10 ")
      assert cart.code == "SAVE10"
    end

    test "rejects an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert cart.code == "FREESHIP"
    end

    test "keeps the previous code when a new one is rejected" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert Cart.apply_code(cart, "BOGUS") == {:error, :unknown_code}
      assert cart.code == "SAVE10"
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 100, "PEAR" => 250}

    test "adds the standard shipping fee to the subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, not off shipping" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 405 + 499
    end

    test "rounds the discount down to whole cents" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_code("SAVE10")

      # 10% of 105 is 10.5 cents; the discount is rounded down to 10.
      prices = %{"APPLE" => 105}
      assert Cart.total_cents(cart, prices) == 95 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 200
    end

    test "raises when a SKU has no price" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end

  describe "total_quantity/1" do
    test "sums the units of every item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_quantity(cart) == 3
    end
  end
end
