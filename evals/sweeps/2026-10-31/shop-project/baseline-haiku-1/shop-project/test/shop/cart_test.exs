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
    test "removes some units and keeps the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity equals the units in the cart" do
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

    test "does nothing for a SKU not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a known code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert cart.discount_code == "SAVE10"
    end

    test "ignores case and surrounding whitespace" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "  freeship ")
      assert cart.discount_code == "FREESHIP"
    end

    test "rejects an unknown code and leaves the cart unchanged" do
      cart = Cart.new()
      assert Cart.apply_discount_code(cart, "NOPE") == {:error, :unknown_code}
    end

    test "a new valid code replaces the previous one" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    test "adds the shipping fee when there is no code" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2)

      assert Cart.total_cents(cart, @prices) == 200 + 499
    end

    test "sums the price of every unit" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 200 + 500 + 499
    end

    test "SAVE10 takes 10% off the item subtotal, not the shipping" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 180 + 499
    end

    test "SAVE10 rounds the discount down to a whole cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      cart = Cart.add_item(cart, "PEAR", 1)

      # subtotal 350, discount 35, shipping 499
      assert Cart.total_cents(cart, @prices) == 315 + 499
    end

    test "FREESHIP waives the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 200
    end

    test "raises when a SKU in the cart has no price" do
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
