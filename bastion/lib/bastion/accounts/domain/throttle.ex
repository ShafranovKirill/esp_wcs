defmodule Bastion.Accounts.Domain.Throttle do
  @free_attempts 5
  @base_s 5
  @max_s 15 * 60

  @type t :: %{failures: non_neg_integer(), locked_until: integer() | nil}

  @spec new() :: t()
  def new, do: %{failures: 0, locked_until: nil}

  @spec wait_seconds(t(), integer()) :: non_neg_integer()
  def wait_seconds(%{locked_until: nil}, _now), do: 0
  def wait_seconds(%{locked_until: until}, now), do: max(until - now, 0)

  @spec failure(t(), integer()) :: t()
  def failure(%{failures: failures}, now) do
    failures = failures + 1

    locked_until =
      if failures > @free_attempts do
        pause = min(@base_s * Integer.pow(2, failures - @free_attempts - 1), @max_s)
        now + pause
      end

    %{failures: failures, locked_until: locked_until}
  end
end
