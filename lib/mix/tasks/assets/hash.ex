defmodule Mix.Tasks.Assets.Hash do
  @moduledoc """
  Creates sha256 hashes for each .js and .css file in `./assets`, and
  writes them to `./priv/static/asset_hashes.txt`. This file is then read
  at compile-time in the router for inclusion in the CSP header.
  """
  @shortdoc "Saves hashes of JavaScript and CSS assets to a file."

  use Mix.Task

  @hashes_file Path.expand("../../../../priv/static/asset_hashes.txt", __DIR__)
  @assets_dir Path.expand("../../../../priv/static/assets", __DIR__)
  @suffixes ~w|.js .css|

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Hashing assets into #{@hashes_file}…")

    @assets_dir
    |> ls_absolute!()
    |> stream_asset_files()
    |> Stream.map(&{&1, hash_file(&1)})
    |> Enum.reduce(File.open!(@hashes_file, [:write]), &write_to_file/2)
    |> File.close()
    |> then(&Mix.shell().info("Result: #{inspect(&1)}"))
  end

  defp stream_asset_files(files_and_dirs) do
    files_and_dirs
    |> Stream.flat_map(&stream_asset_files_recursively/1)
    |> Stream.filter(&String.ends_with?(&1, @suffixes))
  end

  defp stream_asset_files_recursively(path) do
    if File.dir?(path) do
      path
      |> ls_absolute!()
      |> stream_asset_files()
    else
      [path]
    end
  end

  defp ls_absolute!(dir) do
    dir
    |> File.ls!()
    |> Stream.map(&Path.join(dir, &1))
  end

  defp hash_file(file_path) do
    file_path
    |> File.stream!(256)
    # |> Stream.intersperse([?\n])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn content, hash_state ->
      :crypto.hash_update(hash_state, content)
    end)
    # |> :crypto.hash_update("\n")
    |> :crypto.hash_final()
    |> Base.encode64(padding: true)
  end

  defp write_to_file({data_path, data}, file) do
    IO.puts(file, [Path.relative_to(data_path, @assets_dir), ?:, "sha256-", data])
    file
  end
end
