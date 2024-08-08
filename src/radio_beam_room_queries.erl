-module(radio_beam_room_queries).

-export([joined/1, has_membership/1, timeline_from/7, passes_filter/4, can_view_event/3, get_nearest_event_after/6, get_nearest_event_before/6]).

-include_lib("stdlib/include/qlc.hrl").

%% Returns all room IDs the user is currently joined to %%
joined(UserId) ->
  qlc:q([RoomId || {_Table, RoomId, _, _, State, _} <- mnesia:table('Elixir.RadioBeam.Room'),
                   is_joined(UserId, State)]).

is_joined(UserId, State) ->
  case membership(UserId, State) of
    <<"join">> -> true;
    _ -> false
  end.

membership(UserId, State) ->
  case State of
    #{{<<"m.room.member">>, UserId} := #{<<"content">> := #{<<"membership">> := Membership}}} -> Membership;
    _ -> <<"leave">>
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


get_nearest_event_before(RoomId, UserId, Filter, Timestamp, TimestampCutoff, LatestJoinedAtDepth) ->
  qlc:q([
    PDU || {_Table, {RoomId_, _, OriginServerTS}, _, _, Content,  _,  _, _,  Sender, _, _, Type, _} = PDU <- mnesia:table('Elixir.RadioBeam.PDU.Table'),
    RoomId =:= RoomId_,
    OriginServerTS =< Timestamp,
    OriginServerTS >= Timestamp - TimestampCutoff,
    can_view_event(UserId, LatestJoinedAtDepth, PDU),
    passes_filter(Filter, Type, Sender, Content)
  ]).

get_nearest_event_after(RoomId, UserId, Filter, Timestamp, TimestampCutoff, LatestJoinedAtDepth) ->
  qlc:q([
    PDU || {_Table, {RoomId_, _, OriginServerTS}, _, _, Content,  _,  _, _,  Sender, _, _, Type, _} = PDU <- mnesia:table('Elixir.RadioBeam.PDU.Table'),
    RoomId =:= RoomId_,
    OriginServerTS >= Timestamp,
    OriginServerTS =< Timestamp + TimestampCutoff,
    can_view_event(UserId, LatestJoinedAtDepth, PDU),
    passes_filter(Filter, Type, Sender, Content)
  ]).

%% Returns a QLC query for a timeline of room events for the given user, 
%% starting at the event(s) just after LastSyncDepth, ending at 
%% EndTimelineDepth
timeline_from(RoomId, UserId, Filter, EndTimelineDepth, LastSyncDepth, LatestJoinedAtDepth, IgnoredUserIds) ->
  qlc:q([
    PDU || {_Table, {RoomId_, Depth, _}, _, _, Content,  _,  _, _,  Sender, _, _, Type, _} = PDU <- mnesia:table('Elixir.RadioBeam.PDU.Table'),
    RoomId =:= RoomId_,
    -Depth =< EndTimelineDepth,
    -Depth > LastSyncDepth,
    can_view_event(UserId, LatestJoinedAtDepth, PDU),
    not lists:member(Sender, IgnoredUserIds),
    passes_filter(Filter, Type, Sender, Content)
  ]).


passes_filter(F, Type, Sender, Content) ->
  url_filter(F, Content) andalso type_filter(F, Type) andalso sender_filter(F, Sender).
  
url_filter(#{contains_url := none}, _) -> true;
url_filter(#{contains_url := true}, #{<<"url">> := _}) -> true;
url_filter(#{contains_url := false}, Content) when not is_map_key(<<"url">>, Content) -> true;
url_filter(_, _) -> false.

%% TOIMPL: support for * wildcards in types
type_filter(#{types := {allowlist, Allowlist}}, Type) -> lists:member(Type, Allowlist);
type_filter(#{types := {denylist, Denylist}}, Type) -> not lists:member(Type, Denylist);
type_filter(#{types := none}, _) -> true.

sender_filter(#{senders := {allowlist, Allowlist}}, Sender) -> lists:member(Sender, Allowlist);
sender_filter(#{senders := {denylist, Denylist}}, Sender) -> not lists:member(Sender, Denylist);
sender_filter(#{senders := none}, _) -> true.


%% Returns `true` if a user can see an event given their Membership and the
%% room's history_visibility setting at the time of the event
%%
%% Per 10.14.3, if the event in question is the user's own m.room.member event,
%% or a new m.room.history_visibility event, this function should be called 
%% twice (once with the membership/visibility before the event is applied to 
%% the state, and once after), with the results `or`'d together
can_view_event(UserId, LatestJoinedAtDepth, {_Table, {_, Depth, _}, _, _, Content,  _,  _, PrevState, _, _, StateKey, Type, _}) ->
    Membership = membership(UserId, PrevState),
    IsJoinedLater = -Depth =< LatestJoinedAtDepth,
    HistoryVis = history_visibility(PrevState),
    can_view_event(Membership, IsJoinedLater, HistoryVis) or can_view_event_with_next_state(Membership, IsJoinedLater, HistoryVis, Type, Content, StateKey, UserId);

can_view_event(_, _, <<"world_readable">>) -> true;
can_view_event(<<"join">>, _, _) -> true;
can_view_event(_, IsJoinedLater, <<"shared">>) -> IsJoinedLater;
can_view_event(<<"invite">>, _, <<"invited">>) -> true;
can_view_event(_, _, _) -> false.


%% Performs a `can_view_event/3` check, but only if the event is the user's own
%% m.room.member, or an m.room.history_visibility event, and uses the state
%% after applying those events for the check.
can_view_event_with_next_state(Membership, IsJoinedLater, HistoryVis, <<"m.room.member">>, Content, UserId, UserId) ->
  case Content of
    #{<<"membership">> := NewMembership} -> can_view_event(NewMembership, IsJoinedLater, HistoryVis);
    _ -> can_view_event(Membership, IsJoinedLater, HistoryVis)
  end;
can_view_event_with_next_state(Membership, IsJoinedLater, HistoryVis, <<"m.room.history_visibility">>, Content, _, _) ->
  case Content of
    #{<<"history_visibility">> := NewHistoryVis} -> can_view_event(Membership, IsJoinedLater, NewHistoryVis);
    _ -> can_view_event(Membership, IsJoinedLater, HistoryVis)
  end;
can_view_event_with_next_state(_, _, _, _, _, _, _) -> false.


history_visibility(State) ->
  case State of
    #{{<<"m.room.history_visibility">>, <<"">>} := #{<<"content">> := #{<<"history_visibility">> := Vis}}} when Vis == <<"world_readable">>; Vis == <<"shared">>; Vis == <<"invited">>; Vis == <<"joined">> -> Vis;
    %% By default if no history_visibility is set, or if the value is not 
    %% understood, the visibility is assumed to be shared.
    _ -> <<"shared">>
  end.
