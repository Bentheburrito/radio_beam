defmodule RadioBeamWeb.Schemas.Account do
  @moduledoc false

  alias Polyjuice.Util.Schema

  def put_pusher do
    Schema.any_of([
      %{
        "kind" => Schema.enum([nil]),
        "app_id" => :string,
        "pushkey" => :string
      },
      %{
        "app_display_name" => :string,
        "app_id" => :string,
        "append" => [:boolean, default: false],
        "data" => &any_map/1,
        "device_display_name" => :string,
        "kind" => :string,
        "lang" => :string,
        "profile_tag" => [:string, :optional],
        "pushkey" => :string
      }
    ])
  end

  def put_push_rule do
    %{
      "rule_id" => :string,
      "kind" => push_rule_kind(),
      "actions" => [Schema.array_of(push_rule_action()), default: []],
      "conditions" => [Schema.array_of(push_rule_condition()), default: []]
    }
  end

  def get_push_rule do
    %{
      "rule_id" => :string,
      "kind" => push_rule_kind()
    }
  end

  def delete_push_rule do
    %{
      "rule_id" => :string,
      "kind" => push_rule_kind()
    }
  end

  defp push_rule_kind do
    Schema.enum(%{"override" => :override, "underride" => :underride})
  end

  defp push_rule_action do
    Schema.any_of([Schema.enum(["notify"]), %{"set_tweak" => :string}, %{"set_tweak" => :string, "value" => :string}])
  end

  defp push_rule_condition do
    Schema.any_of([%{"kind" => Schema.enum(["event_match"]), "key" => :string, "pattern" => :string}])
  end

  defp any_map(map) when is_map(map), do: {:ok, map}
  defp any_map(_not_a_map), do: {:error, :invalid}

  def put_tag, do: %{"order" => [&order/1, default: 1.0]}

  defp order(value) do
    if is_number(value) and value > 0 and value < 1 do
      {:ok, value}
    else
      {:error, :invalid_order}
    end
  end
end
