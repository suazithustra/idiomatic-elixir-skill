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

    test "removes the item when all of its units are removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when more units than the cart holds are removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "does nothing when the SKU is not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a known code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert cart.discount_code == "SAVE10"
    end

    test "trims and ignores case" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "  freeship ")
      assert cart.discount_code == "FREESHIP"
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "NOPE") == {:error, :unknown_code}
    end

    test "replaces the code already on the cart" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 250, "PEAR" => 300}

    test "sums item prices and adds the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 800 + 499
    end

    test "takes 10% off the item subtotal, not the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      # Subtotal 500, minus 50 off, plus 499 shipping.
      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "rounds the discount down to whole cents" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      # 10% of 250 is 25; 10% of 255 would be 25.5, rounded down to 25.
      assert Cart.total_cents(cart, %{"APPLE" => 255}) == 230 + 499
    end

    test "FREESHIP waives the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 500
    end

    test "an empty cart pays only the shipping fee" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
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
