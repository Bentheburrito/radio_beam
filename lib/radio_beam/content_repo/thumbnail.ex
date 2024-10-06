defmodule RadioBeam.ContentRepo.Thumbnail do
  @moduledoc """
  A thin abstraction over `Vix.Vips.{Image, Operation}`
  """
  defstruct ~w|image source type|a

  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @allowed_file_types ~w|gif heif png webp jpg jpeg|
  def allowed_file_types, do: @allowed_file_types

  @allowed_specs [{32, 32, :crop}, {96, 96, :crop}, {320, 240, :scale}, {640, 480, :scale}, {800, 600, :scale}]
  def allowed_specs, do: @allowed_specs

  @opaque t() :: %__MODULE__{
            image: nil | :use_source | Image.t(),
            source: nil | {Image.t(), Path.t()},
            type: String.t()
          }

  @type spec() :: {width :: non_neg_integer(), height :: non_neg_integer(), :crop | :scale}

  @spec new!(String.t()) :: t() | no_return()
  def new!(type) when type in @allowed_file_types, do: %__MODULE__{image: nil, source: nil, type: type}

  def image(%__MODULE__{image: nil}), do: nil
  def image(%__MODULE__{image: %Image{} = image}), do: image
  def image(%__MODULE__{image: :use_source, source: {image, _path}}), do: image

  def source_image(%__MODULE__{source: nil}), do: nil
  def source_image(%__MODULE__{source: {source_image, _path}}), do: source_image

  @spec load_source_from_path!(t(), Path.t()) :: t()
  def load_source_from_path!(%__MODULE__{} = thumbnail, path) do
    {%Image{} = image, _flags} = load_image!(thumbnail.type, path)

    %__MODULE__{thumbnail | source: {image, path}}
  end

  @spec generate!(t(), spec(), boolean()) :: t()
  def generate!(%__MODULE__{source: {source_image, _path}} = thumbnail, spec, animated?) do
    case thumbnail_image!(source_image, spec, animated?) do
      %Image{} = image -> %__MODULE__{thumbnail | image: image}
      :noop -> %__MODULE__{thumbnail | image: :use_source}
    end
  end

  @spec save_to_path!(t(), Path.t()) :: t()
  def save_to_path!(%__MODULE__{image: %Image{}} = thumbnail, path) do
    save_image!(thumbnail.type, thumbnail.image, path)
    thumbnail
  end

  # :use_source means we want to use the original image as its own thumbnail,
  # so simply link to the original image file.
  def save_to_path!(%__MODULE__{image: :use_source, source: {_image, source_path}} = thumbnail, path) do
    File.ln!(source_path, path)
    thumbnail
  end

  defp thumbnail_image!(%Image{} = image, {width, height, method} = _spec, _animated?) do
    # TODO: adjust for :animated? 
    thumbnail_opts =
      case method do
        :crop -> [crop: :VIPS_INTERESTING_CENTRE] ++ default_thumbnail_opts(height)
        :scale -> default_thumbnail_opts(height)
      end

    # Conduit has similar logic to decide whether to return the original image.
    if Image.width(image) < width or Image.height(image) < height do
      :noop
    else
      Operation.thumbnail_image!(image, width, thumbnail_opts)
    end
  end

  defp default_thumbnail_opts(height), do: [height: height, size: :VIPS_SIZE_DOWN]

  defp load_image!("gif", path), do: Operation.gifload!(path)
  defp load_image!("heif", path), do: Operation.heifload!(path)
  defp load_image!("png", path), do: Operation.pngload!(path)
  defp load_image!("webp", path), do: Operation.webpload!(path)
  defp load_image!(type, path) when type in ~w|jpg jpeg|, do: Operation.jpegload!(path)

  # not sure why this is needed - all other :compression opts (including the
  # default) fail to write. Just a "my machine" thing or something to upstream?
  @heif_opts [compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1]
  defp save_image!("gif", image, path), do: Operation.gifsave!(image, path)
  defp save_image!("heif", image, path), do: Operation.heifsave!(image, path, @heif_opts)
  defp save_image!("png", image, path), do: Operation.pngsave!(image, path)
  defp save_image!("webp", image, path), do: Operation.webpsave!(image, path)
  defp save_image!(type, image, path) when type in ~w|jpg jpeg|, do: Operation.jpegsave!(image, path)
end
