defmodule GenEventTest do
  use ExUnit.Case, async: true

  defmodule LoggerHandler do
    use GenEvent

    def handle_event({:log, x}, messages) do
      { :ok, [x|messages] }
    end

    def handle_call(:messages, messages) do
      { :ok, Enum.reverse(messages), [] }
    end
  end

  @receive_timeout 1000

  test "start_link/2 and handler workflow" do
    { :ok, pid } = GenEvent.start_link()

    { :links, links } = Process.info(self, :links)
    assert pid in links

    assert GenEvent.notify(pid, { :log, 0 }) == :ok
    assert GenEvent.add_handler(pid, LoggerHandler, []) == :ok
    assert GenEvent.notify(pid, { :log, 1 }) == :ok
    assert GenEvent.notify(pid, { :log, 2 }) == :ok

    assert GenEvent.call(pid, LoggerHandler, :messages) == [1, 2]
    assert GenEvent.call(pid, LoggerHandler, :messages) == []

    assert GenEvent.remove_handler(pid, LoggerHandler, []) == :ok
    assert GenEvent.stop(pid) == :ok
  end

  test "start/2 with linked handler" do
    { :ok, pid } = GenEvent.start()

    { :links, links } = Process.info(self, :links)
    refute pid in links

    assert GenEvent.add_handler(pid, LoggerHandler, [], link: true) == :ok

    { :links, links } = Process.info(self, :links)
    assert pid in links

    assert GenEvent.notify(pid, { :log, 1 }) == :ok
    assert GenEvent.sync_notify(pid, { :log, 2 }) == :ok

    assert GenEvent.call(pid, LoggerHandler, :messages) == [1, 2]
    assert GenEvent.stop(pid) == :ok
  end

  test "start/2 with linked swap" do
    { :ok, pid } = GenEvent.start()

    assert GenEvent.add_handler(pid, LoggerHandler, []) == :ok

    { :links, links } = Process.info(self, :links)
    refute pid in links

    assert GenEvent.swap_handler(pid, LoggerHandler, [], LoggerHandler, [], link: true) == :ok

    { :links, links } = Process.info(self, :links)
    assert pid in links

    assert GenEvent.stop(pid) == :ok
  end

  test "start/2 with registered name" do
    { :ok, _ } = GenEvent.start(local: :logger)
    assert GenEvent.stop(:logger) == :ok
  end

  test "stream/2 is enumerable" do
    # Start a manager
    { :ok, pid } = GenEvent.start_link()

    # Also start multiple subscribers
    parent = self()
    spawn_link fn -> send parent, Enum.take(GenEvent.stream(pid), 5) end
    spawn_link fn -> send parent, Enum.take(GenEvent.stream(pid), 3) end
    wait_for_handlers(pid, 2)

    # Notify the events
    for i <- 1..3 do
      GenEvent.sync_notify(pid, i)
    end

    # Receive one of the results
    assert_receive  [1, 2, 3], @receive_timeout
    refute_received [1, 2, 3, 4, 5]

    # Push the remaining events
    for i <- 4..10 do
      GenEvent.sync_notify(pid, i)
    end

    assert_receive [1, 2, 3, 4, 5], @receive_timeout

    # Both subscriptions are gone
    wait_for_handlers(pid, 0)
    GenEvent.stop(pid)
  end

  test "stream/2 with timeout" do
    # Start a manager
    { :ok, pid } = GenEvent.start_link()

    # Start a subscriber with timeout
    parent = self()
    spawn_link fn ->
      send parent, (try do
        Enum.take(GenEvent.stream(pid, timeout: 50), 5)
      catch
        :exit, :timeout -> :timeout
      end)
    end

    assert_receive :timeout, @receive_timeout
  end

  test "stream/2 with manager stop" do
    # Start a manager and subscribers
    { :ok, pid } = GenEvent.start_link()

    parent = self()
    spawn_link fn -> send parent, Enum.take(GenEvent.stream(pid), 5) end
    wait_for_handlers(pid, 1)

    # Notify the events
    for i <- 1..3 do
      GenEvent.sync_notify(pid, i)
    end

    GenEvent.stop(pid)
    assert_receive [1, 2, 3], @receive_timeout
  end

  test "stream/2 with handler removal" do
    # Start a manager and subscribers
    { :ok, pid } = GenEvent.start_link()
    stream = GenEvent.stream(pid)

    parent = self()
    spawn_link fn -> send parent, Enum.take(stream, 5) end
    wait_for_handlers(pid, 1)

    # Notify the events
    for i <- 1..3 do
      GenEvent.sync_notify(pid, i)
    end

    GenEvent.remove_handler(stream)
    assert_receive [1, 2, 3], @receive_timeout
    GenEvent.stop(pid)
  end

  test "stream/2 with duration" do
    # Start a manager and subscribers
    { :ok, pid } = GenEvent.start_link()
    stream = GenEvent.stream(pid, duration: 200)

    parent = self()
    spawn_link fn -> send parent, { :duration, Enum.take(stream, 10) } end
    wait_for_handlers(pid, 1)

    # Notify the events
    for i <- 1..5 do
      GenEvent.sync_notify(pid, i)
    end

    # Wait until the handler is gone
    wait_for_handlers(pid, 0)

    # The stream is not complete but terminated anyway due to duration
    receive do
      { :duration, list } when length(list) <= 5 -> :ok
    after
      0 -> flunk "expected event stream to have finished with 5 or less items"
    end

    GenEvent.stop(pid)
  end

  test "stream/2 with duration and manager stop" do
    # Start a manager and subscribers
    { :ok, pid } = GenEvent.start_link()
    stream = GenEvent.stream(pid, duration: 200)

    parent = self()
    spawn_link fn -> send parent, Enum.take(stream, 5) end
    wait_for_handlers(pid, 1)

    # Notify the events
    for i <- 1..3 do
      GenEvent.sync_notify(pid, i)
    end

    GenEvent.stop(pid)
    assert_receive [1, 2, 3], @receive_timeout

    # Timeout message does not leak
    ref = stream.ref
    refute_received { :timeout, ^ref }
  end

  defp wait_for_handlers(pid, count) do
    unless length(GenEvent.which_handlers(pid)) == count do
      wait_for_handlers(pid, count)
    end
  end
end
