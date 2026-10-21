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

    test "removes the item when the quantity equals the cart's units" do
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

  describe "apply_discount/2" do
    test "accepts a known code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert cart.discount == "SAVE10"
    end

    test "accepts a code typed in lower case with surrounding spaces" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "  freeship ")
      assert cart.discount == "FREESHIP"
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount(Cart.new(), "NOPE") == {:error, :unknown_code}
    end

    test "replaces the code already on the cart" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert cart.discount == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 200, "PEAR" => 150}

    test "adds the shipping fee when there is no discount" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 550 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("SAVE10")

      assert Cart.total_cents(cart, @prices) == 495 + 499
    end

    test "rounds the percentage discount down to whole cents" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("SAVE10")

      # 10% of 155 is 15.5 cents, so the discount is 15 cents
      assert Cart.total_cents(cart, %{"PEAR" => 155}) == 155 - 15 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 400
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
