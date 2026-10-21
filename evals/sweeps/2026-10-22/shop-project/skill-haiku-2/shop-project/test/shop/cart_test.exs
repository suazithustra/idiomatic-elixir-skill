defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Shop.Cart

  @prices %{"APPLE" => 150, "PEAR" => 200}

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

    test "ignores a SKU that is not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 regardless of case and surrounding spaces" do
      assert {:ok, %Cart{code: :save10}} = Cart.apply_code(Cart.new(), " save10 ")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "rejects an unknown code and reports it" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_code(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    test "adds the shipping fee when no code is applied" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.total_cents(cart, @prices) == 300 + 499
    end

    test "sums quantities across items" do
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
        |> Cart.apply_code("SAVE10")

      # 300 * 0.9 = 270, plus shipping
      assert Cart.total_cents(cart, @prices) == 270 + 499
    end

    test "rounds the discounted subtotal to the nearest cent, halves up" do
      prices = %{"ITEM" => 15}
      {:ok, cart} = Cart.new() |> Cart.add_item("ITEM", 1) |> Cart.apply_code("SAVE10")

      # 15 * 0.9 = 13.5, which rounds up to 14
      assert Cart.total_cents(cart, prices) == 14 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "raises when a SKU has no price" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end
