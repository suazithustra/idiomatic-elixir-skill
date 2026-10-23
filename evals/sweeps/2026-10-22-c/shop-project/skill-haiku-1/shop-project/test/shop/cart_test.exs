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

    test "removes the item when removing all of its units" do
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

    test "leaves the cart unchanged for an SKU not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts a known code, ignoring case and whitespace" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "  save10 ")
      assert cart.code == :save10
    end

    test "replaces the code already in the cart" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert cart.code == :freeship
    end

    test "rejects an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, {:unknown_code, "BOGUS"}}
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 99}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 399 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, rounding the discount down" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_code("SAVE10")

      # 10% of 99 is 9.9 cents, rounded down to 9
      assert Cart.total_cents(cart, @prices) == 90 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "charges the shipping fee on an empty cart" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
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
