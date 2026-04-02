defmodule RadioBeam.DAGTest do
  use ExUnit.Case, async: true

  alias RadioBeam.DAG
  alias RadioBeam.DAG.Vertex

  for backend <- [DAG.Map] do
    @backend backend
    describe "new!/1" do
      test "creates a new DAG with the given root Vertex" do
        payload = %{a: 1}
        assert %@backend{} = dag = @backend.new!(:akey, payload)

        assert %Vertex{key: :akey, payload: ^payload, parents: [], stream_id: 0} = root = @backend.root!(dag)

        assert [:akey] = @backend.zid_keys(dag)
        assert ^root = @backend.fetch!(dag, :akey)
        assert 1 = @backend.size(dag)
      end
    end

    describe "append!/3" do
      setup do
        root_key = "abcde"
        %{root_key: root_key, dag: @backend.new!(root_key, %{abcde: 123})}
      end

      test "adds a vertex with the given payload to the dag under the given key, and marks it as the new forward extremity",
           %{root_key: root_key, dag: dag} do
        expected_vertex = %Vertex{key: :hello, payload: %{hello: :world}, parents: [root_key], stream_id: 1}

        dag = @backend.append!(dag, :hello, %{hello: :world})

        assert [:hello] = @backend.zid_keys(dag)
        assert ^expected_vertex = @backend.fetch!(dag, :hello)

        expected_vertex2 = %Vertex{key: :hi, payload: %{hi: :there}, parents: [:hello], stream_id: 2}

        dag = @backend.append!(dag, :hi, %{hi: :there})

        assert [:hi] = @backend.zid_keys(dag)
        assert ^expected_vertex2 = @backend.fetch!(dag, :hi)
      end
    end
  end
end
