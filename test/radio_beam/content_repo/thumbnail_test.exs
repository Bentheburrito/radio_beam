defmodule RadioBeam.ContentRepo.ThumbnailTest do
  use ExUnit.Case, async: true

  alias RadioBeam.ContentRepo.Thumbnail
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  describe "coerce_spec/3" do
    test "returns the min-sized spec with the same method that's GTOET the given dimensions" do
      for {w, h, method} = expected_spec <- Thumbnail.allowed_specs(),
          width <- [0, w - 1, w],
          height <- [0, h - 1, h],
          not (width == 0 and height == 0) do
        assert {:ok, ^expected_spec} = Thumbnail.coerce_spec(width, height, method)
      end
    end

    test "returns {:error, :invalid_spec} for bad input" do
      assert {:error, :invalid_spec} = Thumbnail.coerce_spec(-1, 32, :scale)
      assert {:error, :invalid_spec} = Thumbnail.coerce_spec(32, -1, :crop)
      assert {:error, :invalid_spec} = Thumbnail.coerce_spec(32, 32, :upscale_if_needed)
      assert {:error, :invalid_spec} = Thumbnail.coerce_spec(2 ** 32, 2 ** 32, :crop)
    end
  end

  describe "new!/1" do
    test "creates a %Thumbnail{} when given a thumbnailable file type" do
      assert %Thumbnail{} = Thumbnail.new!("gif")
      assert %Thumbnail{} = Thumbnail.new!("png")
    end

    test "raises when given an invalid file type" do
      assert_raise FunctionClauseError, fn -> Thumbnail.new!("pdf") end
    end
  end

  describe "load_source_from_path!/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      image = Operation.black!(500, 500)

      valid_pairs =
        for type <- Thumbnail.allowed_file_types() do
          path = Path.join([tmp_dir, "image.#{type}"])
          write!(image, path)
          {type, path}
        end

      %{pairs: valid_pairs}
    end

    test "loads images of all allowed types", %{pairs: pairs} do
      for {type, path} <- pairs do
        assert %Thumbnail{} = type |> Thumbnail.new!() |> Thumbnail.load_source_from_path!(path)
      end
    end
  end

  describe "generate!/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      {width, height} = {500, 500}
      image = Operation.black!(width, height)

      thumbnails =
        for type <- Thumbnail.allowed_file_types() do
          path = Path.join([tmp_dir, "image.#{type}"])
          write!(image, path)
          type |> Thumbnail.new!() |> Thumbnail.load_source_from_path!(path)
        end

      %{thumbnails: thumbnails, dimensions: {width, height}}
    end

    test "can generate thumbnails for all allowed types and specs", %{thumbnails: thumbnails} do
      for t <- thumbnails, spec <- Thumbnail.allowed_specs() do
        assert %Thumbnail{} = Thumbnail.generate!(t, spec, false)
      end
    end

    test "does not thumbnail image if its dimensions are smaller than the requested thumbnail", %{
      thumbnails: thumbnails,
      dimensions: {width, height}
    } do
      for t <- thumbnails, w <- [width + 1, width + 100], h <- [height + 1, height + 100] do
        thumbnail = Thumbnail.generate!(t, {w, h, :scale}, false)
        assert Thumbnail.source_image(thumbnail) == Thumbnail.image(thumbnail)
      end
    end
  end

  describe "save_to_path/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      {width, height} = {500, 500}
      image = Operation.black!(width, height)

      pairs =
        for type <- Thumbnail.allowed_file_types() do
          path = Path.join([tmp_dir, "image.#{type}"])
          write!(image, path)

          {type,
           type
           |> Thumbnail.new!()
           |> Thumbnail.load_source_from_path!(path)
           |> Thumbnail.generate!({96, 96, :crop}, false)}
        end

      %{pairs: pairs}
    end

    test "saves to the given path", %{tmp_dir: tmp_dir, pairs: pairs} do
      for {type, t} <- pairs do
        path = Path.join([tmp_dir, "image-saved.#{type}"])
        refute File.exists?(path)
        assert ^t = Thumbnail.save_to_path!(t, path)
        assert File.exists?(path)
      end
    end
  end

  defp write!(image, path) do
    # it seems the pre-compiled libvips doesn't play nicely with `Image.write_to_file` and `.heif`
    if String.ends_with?(path, ".heif") do
      Operation.heifsave!(image, path, compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1)
    else
      Image.write_to_file(image, path)
    end
  end
end
