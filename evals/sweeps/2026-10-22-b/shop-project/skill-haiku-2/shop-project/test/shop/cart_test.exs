defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  @prices %{"APPLE" => 100, "PEAR" => 250}

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
    test "removes only the given units when some remain" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the removed units equal the units held" do
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
        |> Cart.remove_item("APPLE", 5)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged when the SKU is not in it" do
      cart = Cart.add_item(Cart.new(), "PEAR", 1)

      assert Cart.remove_item(cart, "APPLE", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "returns an error for a code it does not know" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_discount_code(Cart.new(), "BOGUS")
    end

    test "replaces the code already in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert Cart.total_cents(cart, @prices) == 200
    end
  end

  describe "total_cents/2" do
    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 949
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 904
    end

    test "rounds the SAVE10 discount half up to the nearest cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 105}) == 593
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 450
    end

    test "raises when a SKU in the cart has no price" do
      cart = Cart.add_item(Cart.new(), "KIWI", 1)

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
