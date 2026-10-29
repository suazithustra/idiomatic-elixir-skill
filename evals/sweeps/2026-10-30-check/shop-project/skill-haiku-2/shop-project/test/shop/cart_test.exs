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
    test "removes only the given units when the cart keeps some" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity equals the units held" do
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
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for an sku that is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "applies SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "applies FREESHIP" do
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "accepts a code in any letter case with surrounding spaces" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), " save10 ")
    end

    test "replaces the code already applied" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_code(Cart.new(), "BOGUS")
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
    @prices %{"APPLE" => 150, "PEAR" => 100}

    test "adds the item prices and the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 400 + 499
    end

    test "waives the shipping fee for FREESHIP" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 400
    end

    test "takes 10% off the item subtotal for SAVE10" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 360 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_code("SAVE10")

      assert Cart.total_cents(cart, %{"PEAR" => 105}) == 94 + 499
    end

    test "raises for a sku that has no price" do
      cart = Cart.add_item(Cart.new(), "KIWI", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end
