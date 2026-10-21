defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  @prices %{"APPLE" => 100, "PEAR" => 250, "MELON" => 1005}

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
    test "removes only the given units when the cart holds more" do
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
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"PEAR" => 1}
    end

    test "removes the item when the quantity exceeds the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "ignores a SKU that is not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts SAVE10 and FREESHIP regardless of case and surrounding spaces" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount_code(Cart.new(), " save10 ")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount_code(Cart.new(), "FreeShip")
    end

    test "replaces the code already on the cart" do
      cart = Cart.new()
      {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "rejects an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_discount_code(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    test "adds the shipping fee to the subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 180 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent, halves up" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("MELON", 1)
        |> Cart.apply_discount_code("SAVE10")

      # 10% of 1005 is 100.5 cents, which rounds to 101 off.
      assert Cart.total_cents(cart, @prices) == 904 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 450
    end

    test "raises when the cart holds a SKU missing from the price list" do
      cart = Cart.add_item(Cart.new(), "KIWI", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end
