defmodule Glific.Telegram.Bot do
  @moduledoc false
  @bot :glific

  use ExGram.Bot,
    name: @bot,
    setup_commands: false

  # command("start")
  # command("help", description: "Print the bot's help")

  middleware(ExGram.Middleware.IgnoreUsername)

  @doc false
  def bot, do: @bot

  @doc false
  def handle({:command, :start, _msg}, context) do
    answer(context, "Hi!")
  end

  @doc false
  def handle({:command, :help, _msg}, context) do
    answer(context, "Here is your help:")
  end
end
