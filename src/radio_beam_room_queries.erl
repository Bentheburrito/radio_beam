-module(radio_beam_room_queries).

-export([joined/1, has_membership/1, timeline_from/5, passes_filter/4]).

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
    _ -> nil
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

%%%% UNUSED/WIP/UNTESTED QLC-BASED TIMELINE CODE BELOW %%%%

%% Returns a QLC query for a timeline of room events for the given user, 
%% starting at the event(s) just after LastSyncEventIds, ending at 
%% EndTimelineEventId
timeline_from(UserId, Filter, EndTimelineEventIds, LastSyncEventIds, IgnoredUserIds) ->
  qlc:q([
    PDU || {{_Table, _EventId, _, Content, _, _, _, _, PrevState, _, _RoomId, Sender, _, StateKey, Type, _} = PDU, IsJoinedLater} <- room_table(EndTimelineEventIds, LastSyncEventIds, UserId),
    Membership = membership(UserId, PrevState),
    HistoryVis = history_visibility(PrevState),
    can_view_event(Membership, IsJoinedLater, HistoryVis),
    can_view_event_with_next_state(Membership, IsJoinedLater, HistoryVis, Type, Content, StateKey, UserId),
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

room_table(StartAtEventIds, SkipEventIds, UserId) ->
  ParentEventIds = fun(PduPairs) ->
    ParentIds = lists:flatmap(fun({Pdu, _}) -> element(8, Pdu) end, PduPairs),
    lists:uniq(ParentIds)
  end,
  NextFxn =
    fun
      NextFxn(EventIds, IsJoinedLater) ->
        case lists:filter(fun(EventId) -> not lists:member(EventId, SkipEventIds) end, EventIds) of
          [] -> [];
          Ids -> 
            PduPairs = 
              lists:foldl(fun(EventId, PduPairs) ->
                NewIsJoinedLater = 
                  case PduPairs of
                    [{_, NIJL} | _] -> NIJL;
                    [] -> IsJoinedLater
                  end,
                lists:map(fun(Pdu) -> {Pdu, get_joined_later(NewIsJoinedLater, Pdu, UserId)} end, mnesia:read('Elixir.RadioBeam.PDU', EventId)) ++ PduPairs
              end, [], Ids),
              NewIsJoinedLater = 
                case PduPairs of
                  [{_, NIJL} | _] -> NIJL;
                  [] -> IsJoinedLater
                end,
            PduPairs ++ fun() -> NextFxn(ParentEventIds(PduPairs), NewIsJoinedLater) end
      end
    end,
    InfoFun = fun(keypos) -> 1;
             (is_sorted_key) -> true;
             (is_unique_objects) -> true;
             (indices) -> mnesia:table_info('Elixir.RadioBeam.PDU', index);
             (_) -> undefined
          end,
  qlc:table(fun() -> NextFxn(StartAtEventIds, false) end, {info_fun, InfoFun}).


%% Checks the prev_state of the given PDU if the given UserId is joined to the 
%% room, returning `true` if so. Otherwise, will simply return `true` if the 
%% first arg is `true`
get_joined_later(_, nil, _) -> false;
get_joined_later(true, _, _) -> true;
get_joined_later(IsJoinedLater, FirstPdu, UserId) -> 
  case is_joined(UserId, element(9, FirstPdu)) of
    true -> true;
    false -> IsJoinedLater
  end.


%% timeline_from(RoomId, UserId, EndTimelineEventId, IgnoredUserIds) ->
%%   qlc:q([PDU || {_Table, EventId, _, Content, _, _, _, _, PrevState, _, RoomId, Sender, _, StateKey, Type, _} = PDU <- mnesia:table('Elixir.RadioBeam.PDU'),
%%                    can_view_event(membership(UserId, PrevState), IsJoinedLater, history_visibility(PrevState)) orelse can_view_event_with_next_state(membership(UserId, PrevState), history_visibility(PrevState), Type, Content)]).

%% Returns `true` if a user can see an event given their Membership and the
%% room's history_visibility setting at the time of the event
%%
%% Per 10.14.3, if the event in question is the user's own m.room.member event,
%% or a new m.room.history_visibility event, this function should be called 
%% twice (once with the membership/visibility before the event is applied to 
%% the state, and once after), with the results `or`'d together
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
can_view_event_with_next_state(_, _, _, _, _, _, _) -> true.


history_visibility(State) ->
  case State of
    #{{<<"m.room.history_visibility">>, <<"">>} := #{<<"content">> := #{<<"history_visibility">> := Vis}}} when Vis == <<"world_readable">>; Vis == <<"shared">>; Vis == <<"invited">>; Vis == <<"joined">> -> Vis;
    %% By default if no history_visibility is set, or if the value is not 
    %% understood, the visibility is assumed to be shared.
    _ -> <<"shared">>
  end.
