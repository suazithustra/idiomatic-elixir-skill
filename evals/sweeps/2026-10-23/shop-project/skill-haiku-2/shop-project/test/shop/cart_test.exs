defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Cart

  @prices %{"APPLE" => 150, "PEAR" => 105}

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
    test "lowers the quantity of an item by the units removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the units removed equal the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when more units are removed than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for a SKU not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "stores the discount for a known code" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "accepts a code with surrounding spaces and any letter case" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), " save10 ")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
    end

    test "replaces the code already applied" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(cart, "FREESHIP")
    end
  end

  describe "total_cents/2" do
    test "adds shipping to the subtotal when there is no code" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 2 * 150 + 105 + 499
    end

    test "takes 10% off the subtotal, not the shipping fee, for SAVE10" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 270 + 499
    end

    test "rounds the discount half up to the nearest cent for SAVE10" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_code("SAVE10")

      # 10% of 105 is 10.5 cents, so the discount is 11 cents and 94 cents remain.
      assert Cart.total_cents(cart, @prices) == 95 + 499
    end

    test "waives the shipping fee for FREESHIP" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "raises KeyError for a SKU missing from the price list" do
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
