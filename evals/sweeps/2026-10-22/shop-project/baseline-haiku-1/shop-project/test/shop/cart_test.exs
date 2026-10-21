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

    test "removes the item when the quantity equals what is in the cart" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"PEAR" => 1}
    end

    test "removes the item when the quantity exceeds what is in the cart" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for a SKU that is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts a known code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert cart.discount_code == "SAVE10"
    end

    test "ignores case and surrounding whitespace" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "  freeship ")
      assert cart.discount_code == "FREESHIP"
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount(Cart.new(), "BOGUS") == {:error, :unknown_code}
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert cart.discount_code == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200}

    test "sums item prices and adds shipping" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 300 + 200 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount("SAVE10")

      # subtotal 300, discount 30, shipping 499
      assert Cart.total_cents(cart, @prices) == 300 - 30 + 499
    end

    test "rounds the SAVE10 discount half up to the cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount("SAVE10")

      # subtotal 150, discount 15 exactly
      assert Cart.total_cents(cart, @prices) == 150 - 15 + 499

      prices = %{"ODD" => 5}
      {:ok, cart} = Cart.new() |> Cart.add_item("ODD", 1) |> Cart.apply_discount("SAVE10")

      # subtotal 5, discount 0.5 rounds up to 1
      assert Cart.total_cents(cart, prices) == 5 - 1 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 200
    end

    test "raises when a SKU has no price" do
      cart = Cart.add_item(Cart.new(), "MYSTERY", 1)

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
