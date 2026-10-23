defmodule Payments.Gateway do
  @moduledoc "A card gateway. The real one talks to the network; tests supply their own."

  @callback charge(amount_cents :: pos_integer(), token :: String.t()) ::
              {:ok, charge_id :: String.t()} | {:error, :declined | :unavailable}
end

defmodule Payments.Charger do
  @moduledoc """
  Charges a card through a gateway and logs what the gateway answered, with the request id as metadata.
  """

  require Logger

  @type outcome :: {:ok, String.t()} | {:error, :declined | :unavailable}

  @doc """
  Charges `amount_cents` to the card behind `token`.

  Options: `:gateway`, a module implementing `Payments.Gateway`, and `:request_id`, which every log
  line of this call carries as metadata.
  """
  @spec charge(pos_integer(), String.t(), keyword()) :: outcome()
  def charge(amount_cents, token, opts) do
    gateway = Keyword.fetch!(opts, :gateway)
    request_id = Keyword.fetch!(opts, :request_id)
    Logger.metadata(request_id: request_id)

    case gateway.charge(amount_cents, token) do
      {:ok, charge_id} ->
        Logger.info("charged #{amount_cents} cents", charge_id: charge_id)
        {:ok, charge_id}

      {:error, :declined} = error ->
        Logger.warning("card declined", amount_cents: amount_cents)
        error

      {:error, :unavailable} = error ->
        Logger.error("gateway unavailable, charge not attempted", amount_cents: amount_cents)
        error
    end
  end
end
