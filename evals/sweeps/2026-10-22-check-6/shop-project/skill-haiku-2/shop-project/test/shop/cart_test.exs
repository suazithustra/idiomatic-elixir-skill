defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  @prices %{"APPLE" => 150, "PEAR" => 200, "CHERRY" => 105}

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

    test "removes the item when the quantity equals the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when the quantity exceeds the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{"PEAR" => 1}
    end

    test "returns the cart unchanged for a SKU not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} =
               Cart.apply_discount_code(Cart.new(), "BOGUS")
    end

    test "accepts a known code with surrounding spaces and in lowercase" do
      assert {:ok, %Cart{discount_code: "SAVE10"}} =
               Cart.apply_discount_code(Cart.new(), "  save10 ")
    end

    test "replaces the code already applied" do
      cart = with_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount_code: "FREESHIP"}} =
               Cart.apply_discount_code(cart, "FREESHIP")
    end
  end

  describe "total_cents/2" do
    test "charges the subtotal plus shipping when no code is applied" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 500 + 499
    end

    test "takes 10% off the subtotal with SAVE10" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> with_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "rounds the SAVE10 discount half up to the nearest cent" do
      cart =
        Cart.new()
        |> Cart.add_item("CHERRY", 1)
        |> with_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 94 + 499
    end

    test "waives shipping with FREESHIP" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> with_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "raises KeyError for a SKU missing from the price list" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)
      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end

  defp with_code(cart, code) do
    {:ok, cart} = Cart.apply_discount_code(cart, code)
    cart
  end
end
