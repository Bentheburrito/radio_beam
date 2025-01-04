defmodule RadioBeam.JobTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.Job
  alias RadioBeam.JobTest.TestJobs

  @concurrency 3
  setup %{test: worker} do
    _pid = start_link_supervised!({Job.Processor, workers: [{worker, @concurrency}]})
    :ok
  end

  test "runs a job", %{test: worker} do
    assert :ok = Job.insert(worker, TestJobs, :echo, [self(), :ok])
    assert_receive :ok
  end

  test "runs jobs concurrently up to the max configured concurrency", %{test: worker} do
    ms_to_wait = 200

    for i <- 1..(@concurrency + 1) do
      assert :ok = Job.insert(worker, TestJobs, :echo_after, [self(), {:ok, i}, ms_to_wait])
    end

    Process.sleep(ms_to_wait + 1)

    for i <- 1..@concurrency do
      assert_receive {:ok, ^i}
    end

    last_val = @concurrency + 1
    refute_received {:ok, ^last_val}

    assert_receive {:ok, ^last_val}, ms_to_wait * 2
  end

  test "exhausts all attempts on a repeatedly failing job", %{test: worker} do
    test_pid = self()
    opts = [max_attempts: 2, on_failure: fn _, _, cur_attempt, _ -> send(test_pid, {:attempt, cur_attempt}) end]

    logs =
      capture_log(fn ->
        assert :ok = Job.insert(worker, TestJobs, :blow_up, [], opts)

        assert_receive {:attempt, 1}, 500
        assert_receive {:attempt, 2}, 2100
      end)

    assert logs =~ "(1/2)"
    assert logs =~ "final attempt"
  end

  test "considers :error a task failure", %{test: worker} do
    test_pid = self()
    opts = [max_attempts: 1, on_failure: fn _, _, cur_attempt, _ -> send(test_pid, {:attempt, cur_attempt}) end]

    logs =
      capture_log(fn ->
        assert :ok = Job.insert(worker, TestJobs, :error, [], opts)

        assert_receive {:attempt, 1}, 500
      end)

    assert logs =~ "final attempt"
  end

  test "considers error tuple a task failure", %{test: worker} do
    test_pid = self()
    opts = [max_attempts: 1, on_failure: fn _, _, cur_attempt, _ -> send(test_pid, {:attempt, cur_attempt}) end]

    logs =
      capture_log(fn ->
        assert :ok = Job.insert(worker, TestJobs, :error_with, [:reason], opts)

        assert_receive {:attempt, 1}, 2100
      end)

    assert logs =~ "final attempt"
  end

  defmodule TestJobs do
    def echo(dest, msg), do: send(dest, msg)

    def echo_after(dest, msg, ms) do
      Process.sleep(ms)
      send(dest, msg)
    end

    def blow_up do
      raise "BOOM!"
    end

    def error do
      :error
    end

    def error_with(error) do
      {:error, error}
    end
  end
end
