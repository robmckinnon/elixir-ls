defmodule ElixirLS.LanguageServer.CLI do
  alias ElixirLS.Utils.{WireProtocol, Launch}
  alias ElixirLS.LanguageServer.JsonRpc
  alias ElixirLS.LanguageServer.Build
  require Logger

  def main do
    Application.load(:erts)
    Application.put_env(:elixir, :ansi_enabled, false)
    WireProtocol.intercept_output(&JsonRpc.print/1, &JsonRpc.print_err/1)

    # :logger application is already started
    # replace console logger with LSP
    if Version.match?(System.version(), ">= 1.15.0") do
      :ok = :logger.remove_handler(:default)

      :ok =
        :logger.add_handler(
          Logger.Backends.JsonRpc,
          Logger.Backends.JsonRpc,
          Logger.Backends.JsonRpc.handler_config()
        )
    else
      Application.put_env(:logger, :backends, [Logger.Backends.JsonRpc])

      Application.put_env(:logger, Logger.Backends.JsonRpc,
        level: :debug,
        format: "$message",
        metadata: []
      )

      {:ok, _} = Logger.add_backend(Logger.Backends.JsonRpc)
      :ok = Logger.remove_backend(:console, flush: true)
    end

    Launch.start_mix()

    Application.put_env(:elixir_sense, :logging_enabled, Mix.env() != :prod)
    Build.set_compiler_options()

    start_language_server()

    Logger.info("Started ElixirLS v#{Launch.language_server_version()}")

    Logger.info("Running in #{File.cwd!()}")

    versions = Launch.get_versions()

    Logger.info(
      "ElixirLS built with elixir #{versions.compile_elixir_version} on OTP #{versions.compile_otp_version}"
    )

    Logger.info(
      "Running on elixir #{versions.current_elixir_version} on OTP #{versions.current_otp_version}"
    )

    Logger.info(
      "Protocols are #{unless(Protocol.consolidated?(Enumerable), do: "not ", else: "")}consolidated"
    )

    check_otp_doc_chunks()
    check_elixir_sources()
    check_otp_sources()

    Launch.limit_num_schedulers()

    Mix.shell(ElixirLS.LanguageServer.MixShell)

    Launch.unload_not_needed_apps([:nimble_parsec, :mix_task_archive_deps, :elixir_ls_debugger])

    WireProtocol.stream_packets(&JsonRpc.receive_packet/1)
  end

  defp incomplete_installation_message(hash \\ "") do
    guide =
      "https://github.com/elixir-lsp/elixir-ls/blob/master/guides/incomplete-installation.md"

    "Unable to start ElixirLS due to an incomplete erlang installation. " <>
      "See #{guide}#{hash} for guidance."
  end

  defp start_language_server do
    case Application.ensure_all_started(:language_server, :temporary) do
      {:ok, _} ->
        :ok

      {:error, {:edoc, {~c"no such file or directory", ~c"edoc.app"}}} ->
        message = incomplete_installation_message("#edoc-missing")

        JsonRpc.show_message(:error, message)
        Process.sleep(5000)
        raise message

      {:error, {:dialyzer, {~c"no such file or directory", ~c"dialyzer.app"}}} ->
        message = incomplete_installation_message("#dialyzer-missing")

        JsonRpc.show_message(:error, message)
        Process.sleep(5000)
        raise message

      {:error, _} ->
        message = incomplete_installation_message()

        JsonRpc.show_message(:error, message)
        Process.sleep(5000)
        raise message
    end
  end

  def check_otp_doc_chunks() do
    if match?({:error, _}, Code.fetch_docs(:erlang)) do
      JsonRpc.show_message(:warning, "OTP compiled without EEP48 documentation chunks")

      Logger.warning(
        "OTP compiled without EEP48 documentation chunks. Language features for erlang modules will run in limited mode. Please reinstall or rebuild OTP with appropriate flags."
      )
    end
  end

  def check_elixir_sources() do
    enum_ex_path = Enum.module_info()[:compile][:source]

    unless File.exists?(enum_ex_path, [:raw]) do
      dir = Path.join(enum_ex_path, "../../../..") |> Path.expand()

      Logger.notice(
        "Elixir sources not found (checking in #{dir}). Code navigation to Elixir modules disabled."
      )
    end
  end

  def check_otp_sources() do
    {_module, _binary, beam_filename} = :code.get_object_code(:erlang)

    erlang_erl_path =
      beam_filename
      |> to_string
      |> String.replace(~r/(.+)\/ebin\/([^\s]+)\.beam$/, "\\1/src/\\2.erl")

    unless File.exists?(erlang_erl_path, [:raw]) do
      dir = Path.join(erlang_erl_path, "../../../..") |> Path.expand()

      Logger.notice(
        "OTP sources not found (checking in #{dir}). Code navigation to OTP modules disabled."
      )
    end
  end
end
