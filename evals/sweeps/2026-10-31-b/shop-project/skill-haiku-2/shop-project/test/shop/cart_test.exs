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
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for a sku that is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "stores a known code" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert cart.code == "SAVE10"
    end

    test "accepts a code typed in lower case with spaces around it" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "  freeship ")
      assert cart.code == "FREESHIP"
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert cart.code == "FREESHIP"
    end

    test "returns an error for an unknown code" do
      cart = Cart.new()

      assert Cart.apply_code(cart, "BOGUS") == {:error, :unknown_code}
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 500 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, and keeps the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      # 10% of 500 is 50, so 450 + 499
      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent, halves up" do
      cart = Cart.add_item(Cart.new(), "APPLE", 5)
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      # 10% of 755 is 75.5, which rounds up to 76
      assert Cart.total_cents(cart, %{"APPLE" => 151}) == 755 - 76 + 499
    end

    test "waives the shipping fee with FREESHIP and applies no item discount" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert Cart.total_cents(cart, @prices) == 500
    end

    test "raises when the cart holds a sku the price list does not have" do
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
