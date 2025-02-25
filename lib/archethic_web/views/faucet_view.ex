defmodule ArchethicWeb.FaucetView do
  use ArchethicWeb, :view

  def faucet_rate_limit_message() do
    rate_limit = Application.get_env(:archethic, :faucet_rate_limit)
    expiry = Application.get_env(:archethic, :faucet_rate_limit_expiry, 0)

    "Allowed only #{rate_limit} transactions for the period of #{Archethic.Utils.seconds_to_human_readable(expiry / 1000)}"
  end
end
