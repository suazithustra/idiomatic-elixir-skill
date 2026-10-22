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

    test "removes the item when the quantity matches what the cart holds" do
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
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for a SKU it does not hold" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("PEAR", 1)

      assert cart.items == %{"APPLE" => 2}
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 and FREESHIP" do
      assert {:ok, %Cart{code: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, {:unknown_code, "BOGUS"}}
    end

    test "replaces the code already applied" do
      cart =
        Cart.new()
        |> Cart.apply_code("SAVE10")
        |> elem(1)
        |> Cart.apply_code("FREESHIP")
        |> elem(1)

      assert cart.code == :freeship
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 250, "PEAR" => 300}

    test "adds shipping to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 800 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, rounding half up" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_code("SAVE10")
        |> elem(1)

      assert Cart.total_cents(cart, @prices) == 550 - 55 + 499
    end

    test "waives shipping with FREESHIP" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_code("FREESHIP")
        |> elem(1)

      assert Cart.total_cents(cart, @prices) == 500
    end

    test "charges shipping on an empty cart" do
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
