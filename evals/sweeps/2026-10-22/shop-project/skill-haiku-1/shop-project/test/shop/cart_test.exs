defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Shop.Cart

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
    test "removes some units and keeps the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity equals what the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when asked for more units than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for a SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 and FREESHIP" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "ignores case and surrounding spaces" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "  save10 ")
    end

    test "replaces the code already in the cart" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "rejects an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_code(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    test "adds the shipping fee to the item subtotal" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)

      # 200 + 250 + 499
      assert {:ok, 949} = Cart.total_cents(cart, @prices)
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} = Cart.new() |> Cart.add_item("PEAR", 1) |> Cart.apply_code("SAVE10")

      # 10% of 250 is 25, so 225 plus 499 shipping
      assert {:ok, 724} = Cart.total_cents(cart, @prices)
    end

    test "rounds the SAVE10 discount to the nearest cent, halves up" do
      prices = %{"APPLE" => 105}
      {:ok, cart} = Cart.new() |> Cart.add_item("APPLE", 1) |> Cart.apply_code("SAVE10")

      # 10% of 105 is 10.5, which rounds up to 11, so 94 plus 499 shipping
      assert {:ok, 593} = Cart.total_cents(cart, prices)
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.apply_code("FREESHIP")

      assert {:ok, 200} = Cart.total_cents(cart, @prices)
    end

    test "returns an error when the cart holds a SKU missing from the price list" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert {:error, {:unknown_sku, "MANGO"}} = Cart.total_cents(cart, @prices)
    end
  end
end
