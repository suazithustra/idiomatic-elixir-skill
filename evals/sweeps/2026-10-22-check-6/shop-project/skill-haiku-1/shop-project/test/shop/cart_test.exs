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

  describe "total_quantity/1" do
    test "sums the units of every item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_quantity(cart) == 3
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

    test "removes the item when the quantity equals the units it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when the quantity exceeds the units it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for an SKU that is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "stores the discount for a known code" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "ignores surrounding spaces and letter case" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), " freeship ")
    end

    test "replaces the code already in the cart" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_code(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 301}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 601 + 499
    end

    test "takes 10% off the subtotal, rounded to the nearest cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_code("SAVE10")

      # 301 * 10% = 30.1 cents, rounded to 30
      assert Cart.total_cents(cart, @prices) == 301 - 30 + 499
    end

    test "waives the shipping fee for FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 150
    end

    test "raises when an item in the cart has no price" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end
