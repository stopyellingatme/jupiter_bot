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
  @clear_line "\e[2K"
  @move_up "\e[1A"
  @refresh_interval 250  # Slightly longer refresh interval
  @ansi_clear_screen "\e[2J"
  @ansi_home "\e[H"
  @ansi_hide_cursor "\e[?25l"
  @ansi_show_cursor "\e[?25h"
  @ansi_alt_screen "\e[?1049h"
  @ansi_main_screen "\e[?1049l"
  @ma_dot "·"               # Smaller dot for MA lines
  @price_bar "█"            # Full block for price bars
  @scale_buffer 0.1         # 10% buffer above and below min/max prices for better scaling

  # Colors
  @header_color "\e[33m"  # Yellow
  @reset_color "\e[0m"
  @graph_up_color "\e[32m"    # Green
  @graph_down_color "\e[31m"  # Red
  @graph_neutral_color "\e[36m"  # Cyan
  @short_ma_color "\e[35m"    # Magenta
  @long_ma_color "\e[34m"     # Blue
  @divider "--------------------------------------------------------------------------------"

  # Graph settings
  @graph_width 80
  @graph_height 15  # Reduced from 20
  @price_history_limit 500

  # Number of lines in our status display
  @status_lines 25
  @newlines_before_stats 2

  @max_buffer_size 5    # Maximum number of updates to buffer

  # Add terminal width constants
  @min_graph_width 80
  @price_label_width 10
  @margin_width 3  # For the "│ " separator and space

  @graph_chars ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]  # Unicode block elements
  @ma_short_dot "·"  # Dot for short MA
  @ma_long_dot "○"   # Circle for long MA

  @price_log_cooldown 60_000  # 60 seconds between price logs
  @price_change_threshold 0.02  # 2% change threshold

  @debug_log_limit 10  # Reduced from 15

  # Add color constants for network status
  @green_color "\e[32m"    # Green
  @red_color "\e[31m"      # Red
  @reset_color "\e[0m"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
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
    {graph_height, debug_lines} = adjust_display_sizes()

    [
      "#{@header_color}Jupiter Bot Trading Stats#{@reset_color}",
      @divider,
      "Active Markets:",
      format_market_list(state.markets, state.active_market),
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
      "#{@header_color}System Diagnostics#{@reset_color}",
      format_system_diagnostics(),
      @divider,
      "#{@header_color}Debug Log (Last #{debug_lines} messages)#{@reset_color}"
    ] ++ (Process.get(:debug_logs, ["Initializing..."]) |> Enum.take(debug_lines)) ++ [
      @divider
    ] |> Enum.join("\n")
  end

  # Helper functions to format different parts of the display
  defp format_market_list(markets, active_market) do
    markets
    |> Enum.map(fn {market, data} ->
      active = if market == active_market, do: "* ", else: "  "
      "#{active}#{market}: #{format_price(data.price)} USDC"
    end)
    |> Enum.join("\n")
  end

  defp format_price_info(%{current_price: price, current_position: position} = state) do
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
  def handle_event([:jupiter_bot, :perpetuals, :price_fetch], %{price: price, timestamp: timestamp}, %{market: market}, _state) do
    # Instead of trying to update state directly, use GenServer.cast
    GenServer.cast(__MODULE__, {:update_market, market, %{
      price: price,
      timestamp: timestamp,
      last_update: DateTime.utc_now()
    }})
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

  def handle_event(event_name, _measurements, _metadata, _config) do
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
  def handle_cast({:update_all, price, momentum, position, short_ma, long_ma} = update, state) do
    buffer_update(update)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:price_update, market, _price, _timestamp} = update, state) do
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
            generate_full_price_graph(s)

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

      if price_range <= 0 do
        ["Initializing price range..."]
      else
        # Calculate available width
        total_width = get_terminal_width()
        graph_width = total_width - @price_label_width - @margin_width

        # Take only as many prices as we can display
        prices = history
        |> Enum.take(graph_width)
        |> Enum.map(fn %{price: price} -> price end)
        |> Enum.reverse()

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

  # Helper to calculate MA points
  defp calculate_ma_points(prices, width) do
    prices
    |> Enum.with_index()
    |> Enum.map(fn {_, i} ->
      %{
        short: nil,
        long: nil
      }
    end)
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

  defp get_column_color(current, previous) when is_number(current) and is_number(previous) do
    cond do
      current > previous -> @graph_up_color
      current < previous -> @graph_down_color
      true -> @graph_neutral_color
    end
  end
  defp get_column_color(_, _), do: @graph_neutral_color

  defp format_change(change) when is_number(change) do
    color = get_price_color(change)
    "#{color}#{if change >= 0, do: "▲", else: "▼"} #{abs(change) * 100 |> Float.round(2)}%#{@reset_color}"
  end
  defp format_change(_), do: ""

  defp format_price(price) when is_number(price), do: :erlang.float_to_binary(price, decimals: 4)
  defp format_price(_), do: "N/A"

  defp format_percentage(value) when is_number(value), do: "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  defp format_percentage(_), do: "0.00%"

  # Helper function to calculate moving averages
  defp calculate_ma(prices, period) do
    prices
    |> Enum.take(period)
    |> Enum.reduce(0, &(&1 + &2))
    |> Kernel./(period)
  end

  # Add helper function to log debug messages
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
      # Get network stats
      network_stats = get_network_stats()
      memory = :erlang.memory()

      [
        "Network Stats:",
        "  RPC Status: #{network_stats.rpc_status}",
        "  Last Price Update: #{format_last_update(network_stats.last_update)}",
        "  Updates Received: #{network_stats.updates_received}",
        "  Failed Requests: #{network_stats.failed_requests}",
        "  Connection Uptime: #{network_stats.uptime}",
        "",
        "Memory Usage:",
        "  Total: #{format_bytes(memory[:total])}",
        "  Processes: #{format_bytes(memory[:processes])}",
        "  ETS: #{format_bytes(memory[:ets])}",
        "",
        "Uptime: #{format_uptime()}"
      ] |> Enum.join("\n")
    rescue
      _ -> "System diagnostics temporarily unavailable"
    end
  end

  defp get_network_stats do
    # Get stats from process dictionary
    updates = Process.get(:total_updates, 0)
    failures = Process.get(:failed_requests, 0)
    last_update = Process.get(:last_price_update_time)
    start_time = Process.get(:start_time) || :os.system_time(:second)

    # Calculate uptime
    current_time = :os.system_time(:second)
    uptime = current_time - start_time

    # Determine RPC status based on recent activity
    rpc_status = case last_update do
      nil -> "Initializing"
      time when is_number(time) ->
        if current_time - time > 10 do
          "#{@red_color}Disconnected#{@reset_color}"
        else
          "#{@green_color}Connected#{@reset_color}"
        end
    end

    %{
      rpc_status: rpc_status,
      last_update: last_update,
      updates_received: updates,
      failed_requests: failures,
      uptime: format_duration(uptime)
    }
  end

  defp format_last_update(nil), do: "Never"
  defp format_last_update(timestamp) do
    seconds_ago = :os.system_time(:second) - timestamp
    cond do
      seconds_ago < 5 -> "#{@green_color}Just now#{@reset_color}"
      seconds_ago < 30 -> "#{seconds_ago}s ago"
      true -> "#{@red_color}#{seconds_ago}s ago#{@reset_color}"
    end
  end

  defp format_duration(seconds) do
    {h, m, s} = {
      div(seconds, 3600),
      rem(div(seconds, 60), 60),
      rem(seconds, 60)
    }
    "#{h}h #{m}m #{s}s"
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"
  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"

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

  # Helper to determine if we should log a price update
  defp should_log_price_update?(new_price) do
    current_time = :os.system_time(:millisecond)
    last_log_time = Process.get(:last_price_log_time, 0)

    case Process.get(:last_logged_price) do
      nil ->
        Process.put(:last_logged_price, new_price)
        false
      last_price ->
        time_since_last_log = current_time - last_log_time
        change = abs((new_price - last_price) / last_price)

        if change > @price_change_threshold and time_since_last_log > @price_log_cooldown do
          Process.put(:last_logged_price, new_price)
          Process.put(:last_price_log_time, current_time)
          true
        else
          false
        end
    end
  end

  # Helper to format price change percentage
  defp format_price_change(new_price) do
    case Process.get(:last_logged_price) do
      nil -> "+0.00%"
      last_price ->
        change = ((new_price - last_price) / last_price) * 100
        if change >= 0 do
          "+#{:erlang.float_to_binary(change, decimals: 2)}%"
        else
          "#{:erlang.float_to_binary(change, decimals: 2)}%"
        end
    end
  end

  defp format_moving_averages(%{ma_data: ma_data}) do
    status = "Ready"

    short_ma = case ma_data.short_ma do
      nil -> "Calculating..."
      value -> "#{format_price(value)} USDC"
    end

    medium_ma = case ma_data.medium_ma do
      nil -> "Calculating..."
      value -> "#{format_price(value)} USDC"
    end

    long_ma = case ma_data.long_ma do
      nil -> "Calculating..."
      value -> "#{format_price(value)} USDC"
    end

    [
      "Moving Averages: #{status}",
      "  Short (9):   #{short_ma}",
      "  Medium (21): #{medium_ma}",
      "  Long (50):   #{long_ma}",
    ]
  end

  defp format_debug_logs do
    [
      "Debug Log (Last #{@debug_log_limit} messages)",
      Process.get(:debug_logs, [])
      |> Enum.take(@debug_log_limit)
      |> Enum.join("\n")
    ]
  end

  @impl true
  def handle_cast({:update_market, market, data}, state) do
    state = if is_nil(state), do: %{markets: %{}}, else: state
    markets = Map.get(state, :markets, %{})

    new_state = %{state | markets: Map.put(markets, market, data)}
    {:noreply, new_state}
  end
end
