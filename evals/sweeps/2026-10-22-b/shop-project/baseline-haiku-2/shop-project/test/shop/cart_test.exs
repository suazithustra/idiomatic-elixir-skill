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
    test "removes some units of an item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when every unit is removed" do
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
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "ignores a sku that is not in the cart" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("PEAR", 1)

      assert cart.items == %{"APPLE" => 2}
    end
  end

  describe "apply_discount_code/2" do
    test "applies a known code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert cart.discount_code == "SAVE10"
    end

    test "ignores case and surrounding whitespace" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "  freeship ")
      assert cart.discount_code == "FREESHIP"
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
    end

    test "replaces the code already on the cart" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    test "sums item prices and adds shipping" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, shipping still applies" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 405 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 450
    end
  end
end
