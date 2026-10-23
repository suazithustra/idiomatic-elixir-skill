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

    test "removes the item when the quantity removed equals the quantity held" do
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

  describe "apply_discount_code/2" do
    test "accepts codes regardless of case and surrounding whitespace" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount_code(Cart.new(), " save10 ")

      assert {:ok, %Cart{discount: :free_shipping}} =
               Cart.apply_discount_code(Cart.new(), "FreeShip")
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount == :free_shipping
    end

    test "rejects an unknown code and keeps the current one" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")

      assert Cart.apply_discount_code(cart, "BOGUS") == {:error, {:unknown_code, "BOGUS"}}
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 300}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 600 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      cart = Cart.add_item(Cart.new(), "PEAR", 3)
      {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      assert Cart.total_cents(cart, @prices) == 810 + 499
    end

    test "rounds the SAVE10 discount down to the cent" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      # 10% of 155 is 15.5 cents; the discount is 15, so the total is 140 + 499
      assert Cart.total_cents(cart, %{"APPLE" => 155}) == 140 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "raises when a cart SKU has no price" do
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
