defmodule Glific.Jobs.MinuteWorker do
  @moduledoc """
  Processes the tasks that need to be handled on a minute schedule
  """

  use Oban.Worker, queue: :crontab

  alias Glific.Flags

  @doc """
  Worker to implement cron job functionality as implemented by Oban. This
  is a work in progress and subject to change
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :discard | :ok | {:error, any} | {:ok, any} | {:snooze, pos_integer()}
  def perform(%Oban.Job{args: %{job: :fun_with_flags}}) do
    Flags.out_of_office_update()
    :ok
  end

  def perform(_job), do: :ok
end