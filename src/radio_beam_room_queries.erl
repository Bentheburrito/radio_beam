-module(radio_beam_room_queries).

-export([joined/1, has_membership/1]).

-include_lib("stdlib/include/qlc.hrl").

%% Returns all room IDs the user is currently joined to %%
joined(UserId) ->
  qlc:q([RoomId || {_Table, RoomId, _, _, State, _} <- mnesia:table('Elixir.RadioBeam.Room'),
                   is_joined(UserId, State)]).

is_joined(UserId, State) ->
  case State of
    #{{<<"m.room.member">>, UserId} := #{<<"content">> := #{<<"membership">> := <<"join">>}}} -> true;
    _ -> false
  end.

%% Returns all room IDs the user has an m.room.member state event in %%
has_membership(UserId) ->
  qlc:q([RoomId || {_Table, RoomId, _, _, State, _} <- mnesia:table('Elixir.RadioBeam.Room'),
                   is_member_of(UserId, State)]).
is_member_of(UserId, State) ->
  case State of
    #{{<<"m.room.member">>, UserId} := _} -> true;
    _ -> false
  end.
