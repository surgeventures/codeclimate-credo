defmodule Codeclimate.CLI do
  @moduledoc """
  Credo.CLI is the entrypoint for both the Mix task and the escript.
  It takes the parameters passed from the command line and translates them into
  a Command module (see the `Credo.CLI.Command` namespace), the work directory
  where the Command should run and a `Credo.Execution` object.
  """

  use Bitwise

  alias Credo.Execution
  alias Credo.Sources
  alias Credo.CLI.Filename
  alias Credo.ConfigFile

  @default_dir "."
  @default_command_name "codeclimate"
  @command_map %{
    "categories" => Credo.CLI.Command.Categories,
    "explain" => Credo.CLI.Command.Explain,
    "gen.check" => Credo.CLI.Command.GenCheck,
    "gen.config" => Credo.CLI.Command.GenExecution,
    "help" => Credo.CLI.Command.Help,
    "list" => Credo.CLI.Command.List,
    "suggest" => Credo.CLI.Command.Suggest,
    "version" => Credo.CLI.Command.Version,
    "codeclimate" => Codeclimate.Command,
  }
  @switches [
    all: :boolean,
    all_priorities: :boolean,
    checks: :string,
    crash_on_error: :boolean,
    format: :string,
    help: :boolean,
    ignore_checks: :string,
    min_priority: :integer,
    read_from_stdin: :boolean,
    strict: :boolean,
    verbose: :boolean,
    version: :boolean
  ]
  @aliases [
    a: :all,
    A: :all_priorities,
    c: :checks,
    C: :config_name,
    h: :help,
    i: :ignore_checks,
    v: :version
  ]

  @config_file "/config.json"

  @doc false
  def main(argv) do
    try do
      Credo.start nil, nil

      argv
      |> run()
      |> to_exit_status()
      |> halt_if_failed()
    rescue
      error ->
        IO.puts(:stderr, "Error:")
        IO.inspect(:stderr, error, [])
    end
  end

  @doc "Returns a List with the names of all commands."
  def commands, do: Map.keys(@command_map)

  @doc """
  Returns the module of a given `command`.
      iex> command_for(:help)
      Credo.CLI.Command.Help
  """
  def command_for(nil), do: nil
  def command_for(command) when is_atom(command) do
    command_modules = Map.values(@command_map)
    if Enum.member?(command_modules, command) do
      command
    else
      nil
    end
  end
  def command_for(command) when is_binary(command) do
    if Enum.member?(commands(), command) do
      @command_map[command]
    else
      nil
    end
  end

  defp run(argv) do
    {command_mod, dir, config} = parse_options(argv)

    config |> require_requires()

    command_mod.run(dir, config)
  end

  # Requires the additional files specified in the config.
  defp require_requires(%Execution{requires: requires}) do
    requires
    |> Sources.find
    |> Enum.each(&Code.require_file/1)
  end

  defp parse_options(argv) do
    {switches_kw, args, []} =
      OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    {command_name, dir, args} =
      case args |> List.first |> command_for() do
        nil ->
          {nil, Enum.at(args, 0), args}
        command_name ->
          {command_name, Enum.at(args, 1), args |> Enum.slice(1..-1)}
      end

    dir = dir || @default_dir
    switches = switches_kw |> Enum.into(%{})
    config = dir |> to_config(switches)

    command_name_dir_config(command_name, args, config)
  end

  defp command_name_dir_config(nil, args, %Execution{help: true} = config) do
    command_name_dir_config("help", args, config)
  end
  defp command_name_dir_config(nil, args, %Execution{version: true} = config) do
    command_name_dir_config("version", args, config)
  end
  defp command_name_dir_config(nil, [], config) do
    command_name_dir_config(@default_command_name, [], config)
  end
  defp command_name_dir_config(nil, args, config) do
    if args |> List.first |> Filename.contains_line_no?() do
      command_name_dir_config("explain", args, config)
    else
      command_name_dir_config(@default_command_name, args, config)
    end
  end
  defp command_name_dir_config(command_name, args, config) do
    {command_for(command_name), args, config}
  end

  defp to_config(dir, switches) do
    json = load_json_config()

    dir
    |> Filename.remove_line_no_and_column()
    |> ConfigFile.read_or_default(switches[:config_name])
    |> set_defaults
    |> set_include_paths(json)
  end

  defp load_json_config do
    case File.read @config_file do
      {:ok, config} -> config |> Poison.decode!
      _ -> %{}
    end
  end

  defp set_defaults(config) do
    defaults = %{
      crash_on_error: false,
      all: true,
      min_priority: -99
    }

    execution_config =
      config
      |> Map.from_struct()
      |> Map.merge(defaults)

    struct(Execution, execution_config)
  end

  defp set_include_paths(
    %Execution{files: %{included: ["./**/*.{ex,exs}"]}} = config,
    %{"include_paths" => paths}
  ) when is_list(paths) do
    update_include_paths(config, paths)
  end
  defp set_include_paths(
    %Execution{files: %{included: ["lib/" <> _, "src/" <> _, "web/" <> _, "apps/" <> _]}} = config,
    %{"include_paths" => paths}
  ) when is_list(paths) do
    update_include_paths(config, paths)
  end
  defp set_include_paths(config, _), do: config

  defp update_include_paths(config, paths) do
    paths = paths
    |> List.delete("deps/")
    |> List.delete("build/")
    |> Enum.map(fn (path) ->
      if path |> String.ends_with?("/") do
        "#{path}**/*.{ex,exs}"
      else
        if ~r/\.ex|\.exs$/ |> Regex.match?(path) do
          path
        end
      end
    end)
    |> Enum.reject(&(!&1))

    %Execution{config | files: %{ config.files | included: paths } }
  end

  # Converts the return value of a Command.run() call into an exit_status
  defp to_exit_status(:ok), do: 0
  defp to_exit_status({:error, issues}) do
    issues
    |> Enum.map(&(&1.exit_status))
    |> Enum.reduce(0, &(&1 ||| &2))
  end

  defp halt_if_failed(0), do: nil
  defp halt_if_failed(x), do: x |> System.halt
end
