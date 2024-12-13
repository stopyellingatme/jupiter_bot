defmodule JupiterBotTest do
  use ExUnit.Case
  doctest JupiterBot

  setup do
    # Stop the supervisor if it's already running
    if Process.whereis(JupiterBot.Supervisor) do
      Supervisor.stop(JupiterBot.Supervisor)
    end

    # Start a fresh supervisor for each test
    start_supervised!(JupiterBot.Supervisor)
    :ok
  end
end
