defmodule JupiterBot.Telemetry.ConsoleReporter do
  use GenServer
  require Logger

  @moduledoc """
  Console reporter for displaying real-time trading statistics and system status.

  Event Handlers:
  - [:jupiter_bot, :perpetuals, :price_fetch] - Tracks successful price updates
    * Increments total_updates counter
    * Updates last_price_update_time
    * Payload: %{price: float()}

  - [:jupiter_bot, :perpetuals, :price_fetch_error] - Tracks failed price fetches
    * Increments failed_requests counter
    * Used for monitoring RPC connection health
    * No specific payload requirements

  Network Statistics Tracked:
  - RPC Status (Connected/Disconnected)
  - Last Price Update Time
  - Total Updates Received
  - Failed Request Count
  - Connection Uptime

  The system maintains these stats using Process dictionary for lightweight
  state management across event handlers.
  """

  # ANSI escape codes
  @refresh_interval 250  # Slightly longer refresh interval
  @ansi_home "\e[H"
  @ansi_show_cursor "\e[?25h"
  @ansi_main_screen "\e[?1049l"
  @price_bar "█"            # Full block for price bars
  @scale_buffer 0.1         # 10% buffer above and below min/max prices for better scaling

  # Colors
  @header_color "\e[33m"  # Yellow
  @reset_color "\e[0m"
  @graph_up_color "\e[32m"    # Green
  @graph_down_color "\e[31m"  # Red
  @graph_neutral_color "\e[36m"  # Cyan
  @divider "--------------------------------------------------------------------------------"

  # Graph settings
  @graph_height 15  # Reduced from 20
  @price_history_limit 500

  @max_buffer_size 5    # Maximum number of updates to buffer

  # Add terminal width constants
  @min_graph_width 80
  @price_label_width 10
  @margin_width 3  # For the "│ " separator and space

  # Add color constants for network status
  @green_color "\e[32m"    # Green
  @red_color "\e[31m"      # Red
  @reset_color "\e[0m"

  # Add these near the top with other module attributes
  @network_events [
    [:jupiter_bot, :rpc, :connect],
    [:jupiter_bot, :rpc, :disconnect],
    [:jupiter_bot, :perpetuals, :price_fetch],
    [:jupiter_bot, :perpetuals, :price_fetch_error]
  ]

  @display_height 30  # Default display height

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Initialize network statistics in process dictionary
    Process.put(:network_state, %{
      rpc_status: :initializing,
      last_price_update: nil,
      total_updates: 0,
      failed_requests: 0,
      start_time: System.system_time(:second)
    })

    # Attach network telemetry handlers
    attach_network_handlers()

    # Attach all telemetry handlers
    :telemetry.attach(
      "jupiter-bot-price-updates",
      [:jupiter_bot, :perpetuals, :price_fetch],
      &__MODULE__.handle_event/4,
      nil
    )

    :telemetry.attach(
      "jupiter-bot-strategy-updates",
      [:jupiter_bot, :strategy, :status_update],
      &__MODULE__.handle_event/4,
      nil
    )

    # Add handler for debug events
    :telemetry.attach(
      "jupiter-bot-debug-logs",
      [:jupiter_bot, :strategy, :debug],
      &__MODULE__.handle_event/4,
      nil
    )

    initial_state = %{
      current_price: nil,
      current_position: :none,
      price_history: [],
      min_price: nil,
      max_price: nil,
      ma_data: %{
        short_ma: nil,
        medium_ma: nil,
        long_ma: nil,
        momentum: 0.0,
        trend_strength: 0.0
      },
      current_signal: :none,
      last_signal_strength: 0.0,
      markets: %{},
      active_market: "SOL-USDC",
      last_update: DateTime.utc_now()
    }

    # Add initial debug log
    add_debug_log("Console reporter initialized")

    # Start the refresh loop
    schedule_refresh()

    {:ok, initial_state}
  end

  @impl true
  def handle_info(:refresh_display, state) do
    # Get and clear the update buffer
    updates = Process.get(:update_buffer, [])
    Process.put(:update_buffer, [])

    # Apply all buffered updates
    new_state = Enum.reduce(updates, state, fn update, acc ->
      apply_update(update, acc)
    end)

    # Only print if we have updates or every 1 second
    if length(updates) > 0 or :os.system_time(:millisecond) - Process.get(:last_print, 0) >= 1000 do
      do_print_stats(new_state)
      Process.put(:last_print, :os.system_time(:millisecond))
    end

    schedule_refresh()
    {:noreply, new_state}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_display, @refresh_interval)
  end

  defp do_print_stats(state) do
    try do
      IO.write(@ansi_home)
      output = build_output(state)
      IO.write(output)
    rescue
      error ->
        IO.write("\n#{@ansi_home}Jupiter Bot - Display Error: #{inspect(error)}\n")
        add_debug_log("Display error: #{inspect(error)}")
    end
  end

  defp build_output(state) do
    {_graph_height, debug_lines} = adjust_display_sizes()

    [
      "#{@header_color}Jupiter Bot Trading Stats#{@reset_color}",
      @divider,
      format_price_info(state),
      "",
      format_momentum_info(state),
      "",
      format_ma_info(state),
      "",
      format_signal_info(state),
      "Last Update: #{state.last_update |> DateTime.to_time() |> Time.to_string()}",
      @divider,
      "#{@header_color}Price Graph (Last #{length(state.price_history)} updates)#{@reset_color}"
    ] ++ generate_price_graph(state) ++ [
      @divider,
      "#{@header_color}System Information#{@reset_color}",
      format_system_diagnostics(),
      @divider,
      "#{@header_color}Debug Log (Last #{debug_lines} messages)#{@reset_color}"
    ] ++ (Process.get(:debug_logs, ["Initializing..."]) |> Enum.take(debug_lines)) ++ [
      @divider
    ] |> Enum.join("\n")
  end

  # Helper functions to format different parts of the display
  defp format_price_info(%{current_price: price, current_position: _position} = state) do
    price_str = format_price(price)
    change = calculate_price_change(state)
    change_color = if change >= 0, do: @green_color, else: @red_color
    change_arrow = if change >= 0, do: "▲", else: "▼"

    "Price: #{price_str} USDC #{change_color}#{change_arrow} #{abs(change)}%#{@reset_color}"
  end

  defp format_momentum_info(%{ma_data: nil}), do: "Momentum: Initializing..."
  defp format_momentum_info(%{ma_data: ma_data}) when is_map(ma_data) do
    momentum = Map.get(ma_data, :momentum, 0.0)
    strength = Map.get(ma_data, :trend_strength, 0.0)

    momentum_pct = Float.round(momentum * 100, 2)
    strength_pct = Float.round(strength * 100, 2)

    momentum_color = cond do
      momentum_pct > 1.0 -> @green_color
      momentum_pct < -1.0 -> @red_color
      true -> @reset_color
    end

    [
      "Momentum: #{momentum_color}#{momentum_pct}%#{@reset_color}",
      "Trend Strength: #{strength_pct}%"
    ] |> Enum.join("\n")
  end
  defp format_momentum_info(_), do: "Momentum: Unavailable"

  defp format_ma_info(%{ma_data: nil}), do: "Moving Averages: Waiting for initial data..."
  defp format_ma_info(%{ma_data: ma_data, price_history: history}) when is_map(ma_data) do
    short = Map.get(ma_data, :short_ma)
    medium = Map.get(ma_data, :medium_ma)
    long = Map.get(ma_data, :long_ma)

    # Show how close we are to having enough data
    history_length = length(history)
    [
      "Moving Averages: #{format_data_progress(history_length)}",
      "  Short (9):   #{format_ma_value(short, 9, history_length)}",
      "  Medium (21): #{format_ma_value(medium, 21, history_length)}",
      "  Long (50):   #{format_ma_value(long, 50, history_length)}"
    ] |> Enum.join("\n")
  end
  defp format_ma_info(_), do: "Moving Averages: Initializing..."

  defp format_ma_value(nil, period, history_length) when history_length < period do
    "Collecting data... (#{history_length}/#{period})"
  end
  defp format_ma_value(nil, _period, _history_length), do: "Calculating..."
  defp format_ma_value(value, _period, _history_length), do: format_price(value)

  defp format_data_progress(history_length) do
    cond do
      history_length >= 50 -> "Ready"
      history_length >= 21 -> "Medium MA Ready"
      history_length >= 9 -> "Short MA Ready"
      true -> "Collecting data (#{history_length}/50)"
    end
  end

  defp format_signal_info(%{current_signal: signal, last_signal_strength: strength, current_position: position}) do
    signal_str = case signal do
      :long -> "#{@green_color}BULLISH#{@reset_color}"
      :short -> "#{@red_color}BEARISH#{@reset_color}"
      _ -> "NEUTRAL"
    end

    position_str = case position do
      :long -> "#{@green_color}long#{@reset_color}"
      :short -> "#{@red_color}short#{@reset_color}"
      _ -> "none"
    end

    strength_pct = Float.round((strength || 0.0) * 100, 2)

    [
      "Signal: #{signal_str} (#{position_str})",
      "Signal Strength: #{strength_pct}%"
    ] |> Enum.join("\n")
  end
  defp format_signal_info(_), do: "Signal: Initializing..."

  @impl true
  def handle_event([:jupiter_bot, :perpetuals, :price_fetch], measurements, _metadata, _config) do
    # Update network stats
    Process.put(:total_updates, (Process.get(:total_updates, 0) + 1))
    Process.put(:last_price_update_time, DateTime.utc_now() |> DateTime.to_unix())

    # Log the update for debugging
    add_debug_log("Price update received: #{measurements.price}")

    :ok
  end

  def handle_event([:jupiter_bot, :perpetuals, :price_fetch_error], _measurements, metadata, _config) do
    # Update error count
    Process.put(:failed_requests, (Process.get(:failed_requests, 0) + 1))

    # Log the error for debugging
    add_debug_log("Price fetch error: #{inspect(metadata)}")

    :ok
  end

  def handle_event([:jupiter_bot, :strategy, :status_update], measurements, metadata, _config) do
    # Store debug info in process dictionary
    add_debug_log("Status update: #{metadata.position}")

    GenServer.cast(__MODULE__, {:update_state, %{
      current_price: measurements.price,
      current_position: metadata.position,
      current_signal: metadata.signal,
      last_signal_strength: measurements.signal_strength,
      ma_data: Map.get(measurements, :ma_data, %{
        short_ma: nil,
        medium_ma: nil,
        long_ma: nil,
        momentum: 0.0,
        trend_strength: 0.0
      })
    }})
  end

  def handle_event([:jupiter_bot, :strategy, :momentum_update], measurements, metadata, _config) do
    # Store debug info in process dictionary
    add_debug_log("Momentum update: #{measurements.momentum}")

    GenServer.cast(__MODULE__, {:update_state, %{
      current_momentum: measurements.momentum,
      current_position: metadata[:position]
    }})
  end

  def handle_event([:jupiter_bot, :strategy, :debug], _measurements, %{message: message}, _config) do
    # Add prefix to distinguish MA logs
    add_debug_log("MA: #{message}")
  end

  def handle_event(_event_name, _measurements, _metadata, _config) do
    # Silently handle other events
    :ok
  end

  @impl true
  def handle_cast({:update_state, updates}, state) do
    try do
      new_state = apply_update({:update_state, updates}, state)
      {:noreply, new_state}
    rescue
      error ->
        add_debug_log("State update error: #{inspect(error)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_all, _price, _momentum, _position, _short_ma, _long_ma} = update, state) do
    buffer_update(update)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:price_update, _market, _price, _timestamp} = update, state) do
    buffer_update(update)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:debug_log, message}, state) do
    add_debug_log(message)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_debug_log, message}, state) do
    add_debug_log(message)
    {:noreply, state}
  end

  defp maybe_update_price_history(%{current_price: price} = state) when not is_nil(price) do
    new_history = [
      %{price: price, timestamp: state.last_update}
      | state.price_history
    ]
    |> Enum.take(@price_history_limit)

    %{state | price_history: new_history}
  end
  defp maybe_update_price_history(state), do: state

  defp maybe_update_price_range(%{price_history: history} = state) when length(history) > 1 do
    prices = Enum.map(history, & &1.price)
    min_price = Enum.min(prices)
    max_price = Enum.max(prices)

    # Add buffer to price range for better visualization
    price_range = max_price - min_price
    buffer = max(price_range * @scale_buffer, 0.0001)  # Ensure minimum buffer

    %{state |
      min_price: min_price - buffer,
      max_price: max_price + buffer
    }
  end
  defp maybe_update_price_range(state), do: state

  defp generate_price_graph(state) do
    try do
      case state do
        %{price_history: history, min_price: min_price, max_price: max_price} = s
          when length(history) > 1 and not is_nil(min_price) and not is_nil(max_price) ->
            # Check if price has changed
            last_graph = Process.get(:last_graph_state)
            current_price = List.first(history).price

            if last_graph && last_graph.price == current_price do
              # Return cached graph if price hasn't changed
              last_graph.graph
            else
              # Generate new graph and cache it
              graph = generate_full_price_graph(s)
              Process.put(:last_graph_state, %{price: current_price, graph: graph})
              graph
            end

        %{price_history: [price | _]} ->
            graph_width = get_terminal_width() - 12
            price_label = format_price(price.price)
            line = String.duplicate(@price_bar, graph_width)
            [
              String.pad_leading(format_price(price.price * 1.001), 10) <> " │ ",
              String.pad_leading(price_label, 10) <> " │ #{@graph_neutral_color}#{line}#{@reset_color}",
              String.pad_leading(format_price(price.price * 0.999), 10) <> " │ "
            ]

        _ ->
            add_debug_log("Waiting for initial price data...")
            ["Collecting price data..."]
      end
    rescue
      error ->
        add_debug_log("Graph error: #{inspect(error)}")
        ["Error generating graph - recovering..."]
    end
  end

  defp generate_full_price_graph(%{price_history: history, min_price: min_price, max_price: max_price}) do
    try do
      # Validate price range
      price_range = max_price - min_price

      # Check if prices are too similar
      prices = history
      |> Enum.take(get_terminal_width() - @price_label_width - @margin_width)
      |> Enum.map(fn %{price: price} -> price end)
      |> Enum.reverse()

      price_variance = Enum.max(prices) - Enum.min(prices)

      if price_range <= 0 or price_variance < 0.0001 do
        # If prices are too similar, show a simplified single-line display
        current_price = List.first(prices)
        graph_width = get_terminal_width() - @price_label_width - @margin_width
        line = String.duplicate("─", graph_width)
        [
          String.pad_leading(format_price(current_price * 1.001), @price_label_width) <> " │ ",
          String.pad_leading(format_price(current_price), @price_label_width) <> " │ #{@graph_neutral_color}#{line}#{@reset_color}",
          String.pad_leading(format_price(current_price * 0.999), @price_label_width) <> " │ "
        ]
      else
        # Generate full graph
        _graph_width = get_terminal_width() - @price_label_width - @margin_width
        # We're not using graph_width directly here since the price labels
        # and graph generation use different width calculations

        # Generate price labels with fewer steps
        price_labels = for i <- 0..@graph_height do
          price = max_price - (price_range * (i / @graph_height))
          String.pad_leading(format_price(price), @price_label_width)
        end

        # Generate graph lines
        for y <- 0..(@graph_height - 1) do
          threshold = 1.0 - (y / @graph_height)
          label = Enum.at(price_labels, y)

          line = prices
          |> Enum.map(fn price ->
            normalized = (price - min_price) / price_range
            if normalized >= threshold, do: "█", else: " "
          end)
          |> Enum.join("")

          colored_line = if String.trim(line) != "" do
            color = get_price_color(List.last(prices) - List.first(prices))
            "#{color}#{line}#{@reset_color}"
          else
            line
          end

          "#{label} │ #{colored_line}"
        end
      end
    rescue
      error ->
        add_debug_log("Graph error: #{inspect(error)}")
        ["Initializing graph..."]
    end
  end

  defp calculate_price_change(%{price_history: []}), do: 0.0
  defp calculate_price_change(%{price_history: [_single]}), do: 0.0
  defp calculate_price_change(%{price_history: history}) do
    case Enum.take(history, 2) do
      [%{price: current}, %{price: previous}] ->
        ((current - previous) / previous) * 100
      _ -> 0.0
    end
  end
  defp calculate_price_change(_), do: 0.0

  defp get_price_color(change) when is_number(change) do
    cond do
      change > 0 -> @graph_up_color
      change < 0 -> @graph_down_color
      true -> @graph_neutral_color
    end
  end
  defp get_price_color(_), do: @graph_neutral_color

  defp format_price(price) when is_number(price), do: :erlang.float_to_binary(price, decimals: 4)
  defp format_price(_), do: "N/A"

  defp add_debug_log(message) do
    timestamp = DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
    log_entry = "#{timestamp} | #{message}"

    # Keep last 24 logs (25 including new one)
    Process.put(
      :debug_logs,
      [log_entry | (Process.get(:debug_logs, []) |> Enum.take(24))]
    )
  end

  # Add this function to get terminal width
  defp get_terminal_width do
    case :io.columns() do
      {:ok, width} -> max(@min_graph_width, width)
      _ -> @min_graph_width
    end
  end

  defp update_state_with_price(state, market, price, timestamp) do
    new_markets = Map.update(
      state.markets,
      market,
      %{price: price, history: [%{price: price, timestamp: timestamp}]},
      fn market_data ->
        new_history = [%{price: price, timestamp: timestamp} | market_data.history]
        |> Enum.take(@price_history_limit)
        %{market_data | price: price, history: new_history}
      end
    )

    %{state |
      markets: new_markets,
      current_price: price,
      last_update: timestamp
    }
    |> maybe_update_price_history()
    |> maybe_update_price_range()
  end

  defp buffer_update(update) do
    buffer = Process.get(:update_buffer, [])
    new_buffer = [update | buffer] |> Enum.take(@max_buffer_size)
    Process.put(:update_buffer, new_buffer)
  end

  defp apply_update({:price_update, market, price, timestamp}, state) do
    update_state_with_price(state, market, price, timestamp)
  end

  defp apply_update({:update_all, price, momentum, position, short_ma, long_ma}, state) do
    %{state |
      current_price: price,
      current_momentum: momentum,
      current_position: position,
      short_ma: short_ma,
      long_ma: long_ma,
      last_update: DateTime.utc_now()
    }
    |> maybe_update_price_history()
    |> maybe_update_price_range()
  end

  defp apply_update({:update_state, updates}, state) do
    Map.merge(state, updates)
    |> maybe_update_price_history()
    |> maybe_update_price_range()
  end

  defp format_system_diagnostics do
    try do
      # Get network stats with safer error handling
      network_stats = get_network_stats()

      # Safely get memory info with defaults
      memory = try do
        :erlang.memory()
      rescue
        _ -> %{total: 0, processes: 0}
      end

      # Safely get process count
      process_count = length(:erlang.processes())

      # Calculate error rate safely
      error_rate = if network_stats.updates_received > 0 do
        failures = network_stats.failed_requests || 0
        total = network_stats.updates_received + failures
        "#{Float.round((failures / total) * 100, 2)}%"
      else
        "0.00%"
      end

      [
        "Network Stats:",
        "  RPC Status: #{network_stats.rpc_status}",
        "  Last Price Update: #{network_stats.last_update}",
        "  Updates Received: #{network_stats.updates_received}",
        "  Failed Requests: #{network_stats.failed_requests} (#{error_rate})",
        "  Connection Uptime: #{network_stats.uptime}",
        "",
        "System Stats:",
        "  Process Count: #{process_count}",
        "  Memory Usage: #{format_bytes(memory[:total])}",
        "  Process Memory: #{format_bytes(memory[:processes])}",
        "  System Uptime: #{format_uptime()}"
      ] |> Enum.join("\n")
    rescue
      error ->
        add_debug_log("Diagnostics error details: #{inspect(error, pretty: true)}")
        "System diagnostics recovering... (#{inspect(error.__struct__)})"
    end
  end

  # Add safer network stats handling
  defp get_network_stats do
    network_state = Process.get(:network_state) || %{
      rpc_status: :initializing,
      last_price_update: nil,
      total_updates: 0,
      failed_requests: 0,
      start_time: :os.system_time(:second)
    }

    current_time = :os.system_time(:second)

    # Ensure we have valid numbers for calculations
    updates = network_state.total_updates || 0
    failures = network_state.failed_requests || 0
    start_time = network_state.start_time || current_time

    %{
      rpc_status: format_rpc_status(network_state.rpc_status),
      last_update: format_last_update(network_state.last_price_update),
      updates_received: updates,
      failed_requests: failures,
      uptime: format_duration(max(current_time - start_time, 0))
    }
  end

  # Add helper functions for safer formatting
  defp format_rpc_status(status) do
    case status do
      :connected -> "#{@green_color}Connected#{@reset_color}"
      :disconnected -> "#{@red_color}Disconnected#{@reset_color}"
      _ -> "Initializing"
    end
  end

  defp format_last_update(nil), do: "Never"
  defp format_last_update(timestamp) do
    try do
      seconds_ago = DateTime.diff(DateTime.utc_now(), timestamp)
      cond do
        seconds_ago < 5 -> "#{@green_color}Just now#{@reset_color}"
        seconds_ago < 30 -> "#{seconds_ago}s ago"
        true -> "#{@red_color}#{seconds_ago}s ago#{@reset_color}"
      end
    rescue
      _ -> "Invalid timestamp"
    end
  end

  # Update format_duration to handle edge cases
  defp format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    {h, m, s} = {
      div(seconds, 3600),
      rem(div(seconds, 60), 60),
      rem(seconds, 60)
    }
    "#{h}h #{m}m #{s}s"
  end
  defp format_duration(_), do: "0h 0m 0s"

  # Update format_bytes to handle edge cases
  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / 1024 / 1024, 2)} MB"
      true -> "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"
    end
  end
  defp format_bytes(_), do: "0 B"

  defp format_uptime do
    {time, _} = :erlang.statistics(:wall_clock)
    seconds = div(time, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h #{rem(minutes, 60)}m"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m #{rem(seconds, 60)}s"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp get_terminal_dimensions do
    case :io.rows() do
      {:ok, rows} -> {rows, get_terminal_width()}
      _ -> {@display_height, @min_graph_width}
    end
  end

  defp adjust_display_sizes do
    {rows, _cols} = get_terminal_dimensions()
    available_height = rows - 20  # Reserve space for headers and stats

    graph_height = min(15, div(available_height, 2))
    debug_lines = min(15, div(available_height, 3))

    {graph_height, debug_lines}
  end

  @impl true
  def terminate(_reason, _state) do
    # Restore main screen and cursor
    IO.write(@ansi_show_cursor <> @ansi_main_screen)
    :ok
  end

  defp attach_network_handlers do
    Enum.each(@network_events, fn event_name ->
      :telemetry.attach(
        "network-#{inspect(event_name)}",
        event_name,
        &handle_network_event/4,
        nil
      )
    end)
  end

  defp handle_network_event([:jupiter_bot, :rpc, :connect], _measurements, _metadata, _config) do
    update_network_state(:rpc_status, :connected)
  end

  defp handle_network_event([:jupiter_bot, :rpc, :disconnect], _measurements, _metadata, _config) do
    update_network_state(:rpc_status, :disconnected)
  end

  defp handle_network_event([:jupiter_bot, :perpetuals, :price_fetch], _measurements, _metadata, _config) do
    update_network_state(:last_price_update, DateTime.utc_now())
    update_network_state(:total_updates, &(&1 + 1))
  end

  defp handle_network_event([:jupiter_bot, :perpetuals, :price_fetch_error], _measurements, _metadata, _config) do
    update_network_state(:failed_requests, &(&1 + 1))
  end

  defp update_network_state(key, value_or_fun) do
    current_state = Process.get(:network_state) || %{
      rpc_status: :initializing,
      last_price_update: nil,
      total_updates: 0,
      failed_requests: 0,
      start_time: System.system_time(:second)
    }

    new_value = case value_or_fun do
      fun when is_function(fun, 1) -> fun.(Map.get(current_state, key, 0))
      value -> value
    end

    Process.put(:network_state, Map.put(current_state, key, new_value))
  end
end
