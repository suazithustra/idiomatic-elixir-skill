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
    test "reduces the quantity" do
      cart = Cart.new() |> Cart.add_item("APPLE", 5) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the held units" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{}
    end

    test "removes the item when removing more than the held units" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 9)
      assert cart.items == %{}
    end

    test "ignores SKUs not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{code: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
      assert Cart.apply_code(Cart.new(), "save10") == {:error, :unknown_code}
    end

    test "a new valid code replaces the old one" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(cart, "FREESHIP")
    end
  end

  describe "total/2" do
    @prices %{"APPLE" => 100, "PEAR" => 250}

    setup do
      %{cart: Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)}
    end

    test "adds shipping to the subtotal", %{cart: cart} do
      assert Cart.total(cart, @prices) == 450 + 499
    end

    test "SAVE10 takes 10% off the subtotal but not shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert Cart.total(cart, @prices) == 405 + 499
    end

    test "FREESHIP waives shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert Cart.total(cart, @prices) == 450
    end

    test "raises for a SKU missing from the price list", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 100}) end
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
