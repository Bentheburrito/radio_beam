defmodule RadioBeam.User.Authentication.OAuth2.Builtin.AuthzCodeCache do
  @moduledoc false
  use GenServer

  @expire_authz_code_after_ms :timer.minutes(10)

  ### API ###

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put(code, code_challenge, client_id, %URI{} = redirect_uri, user_id, scope) do
    GenServer.call(__MODULE__, {:put, code, code_challenge, client_id, redirect_uri, user_id, scope})
  end

  def pop(code, code_verifier, client_id, %URI{} = redirect_uri) do
    case GenServer.call(__MODULE__, {:pop, code}) do
      {:ok, %{code_challenge: code_challenge, client_id: ^client_id, redirect_uri: ^redirect_uri} = bound_values} ->
        if code_challenge == Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false) do
          {:ok, bound_values.user_id, bound_values.scope}
        else
          {:error, :invalid_grant}
        end

      _else ->
        {:error, :invalid_grant}
    end
  end

  ### IMPL ###

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:put, code, code_challenge, client_id, redirect_uri, user_id, scope}, _from, state) do
    timer_ref = Process.send_after(self(), {:expire, code}, @expire_authz_code_after_ms)

    associated_data = %{
      code_challenge: code_challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      user_id: user_id,
      scope: scope,
      timer_ref: timer_ref
    }

    {:reply, :ok, Map.put(state, code, associated_data)}
  end

  @impl GenServer
  def handle_call({:pop, code}, _from, state) do
    case Map.pop(state, code, :none) do
      {:none, ^state} ->
        {:reply, :none, state}

      {%{timer_ref: timer_ref} = bound_values, state} ->
        Process.cancel_timer(timer_ref)
        {:reply, {:ok, bound_values}, state}
    end
  end

  @impl GenServer
  def handle_info({:expire, code}, state) do
    {:noreply, Map.delete(state, code)}
  end
end
