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
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "leaves other items alone" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"PEAR" => 1}
    end

    test "does nothing for an item not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts a known code, ignoring case and whitespace" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), " save10 ")
      assert cart.discount == :save10
    end

    test "rejects an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_discount(Cart.new(), "BOGUS")
    end

    test "replaces the code already on the cart" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert cart.discount == :freeship
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 205}

    test "adds the shipping fee when there is no discount" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.total_cents(cart, @prices) == 300 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, not off shipping" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("SAVE10")

      # subtotal 505, discount floor(505 / 10) = 50, shipping 499
      assert Cart.total_cents(cart, @prices) == 455 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "prices the remaining units after a removal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.remove_item("APPLE", 1)

      assert Cart.total_cents(cart, @prices) == 300 + 499
    end
  end
end
