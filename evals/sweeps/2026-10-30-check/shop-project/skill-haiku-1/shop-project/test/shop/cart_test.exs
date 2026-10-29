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
    test "removes some units and keeps the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity equals what the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when the quantity exceeds what the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for an SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 and stores it on the cart" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert cart.code == "SAVE10"
    end

    test "accepts a code with stray spaces and lower case letters" do
      assert {:ok, %Cart{code: "FREESHIP"}} = Cart.apply_code(Cart.new(), "  freeship ")
    end

    test "replaces the code already on the cart" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{code: "FREESHIP"}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
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

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 301}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 301 + 300 + 499
    end

    test "takes 10 percent off the item subtotal with SAVE10" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_code("SAVE10")

      # Subtotal 300, 10 percent off is 30, plus 499 shipping.
      assert Cart.total_cents(cart, @prices) == 270 + 499
    end

    test "rounds the SAVE10 discount half up to the nearest cent" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_code("SAVE10")

      # 10 percent of 301 is 30.1, which rounds to 30 off.
      assert Cart.total_cents(cart, @prices) == 271 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "charges the shipping fee on an empty cart" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
    end
  end
end
