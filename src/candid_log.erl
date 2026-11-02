%%% The panel's log: parse errors, the annotation warnings, what the link says
%%% and what csp itself prints -- `Error: variable Nope is not declared' after
%%% a set, `Paused ...' -- in a window of its own, so they are not lost in a
%%% terminal nobody looks at.
%%%
%%% It is the panel process's GROUP LEADER: whatever the panel and candyspeak
%%% write with io:format comes here, goes on to the terminal as before, and is
%%% kept. Requests that are not output (a read) go straight to the old leader,
%%% which answers the caller itself.
%%%
%%% Like the chat it is its own process, so it lives through every rebuild of
%%% the panel. Its pane is the renderer's (candid_log_wse, candid_log_wx):
%%% pane/2, show/3, add/4, trim/3, clear/2 and event/2.

-module(candid_log).

-export([start/1, add/3, toggle/1, show/1]).

-define(MAX, 2000).                    % lines kept in the pane

%% L is the pane's renderer, {Module, Handle}. The caller's output comes here
%% from now on.
start(L) ->
    Old = group_leader(),
    Log = spawn_link(fun() -> init(L, Old) end),
    group_leader(Log, self()),
    Log.

%% Kind is csp | link | note; the text is one or more lines.
add(undefined, _Kind, _Text) -> ok;
add(Log, Kind, Text) -> Log ! {candid_log, Kind, Text}, ok.

toggle(undefined) -> ok;
toggle(Log) -> Log ! toggle, ok.

%% Open it: something went wrong that the panel cannot show itself.
show(undefined) -> ok;
show(Log) -> Log ! {show, true}, ok.

init(L, Old) ->
    Pane = cui(L, pane, ["log"]),
    loop(#{ui => L, pane => Pane, old => Old, shown => false,
	   part => "", n => 0}).

cui({M, H}, F, A) -> apply(M, F, [H | A]).

pui(#{ui := C, pane := P}, F, A) -> cui(C, F, [P | A]).

loop(S = #{ui := {M, _}, pane := Pane, old := Old}) ->
    receive
	{io_request, From, ReplyAs, Req} ->
	    Old ! {io_request, From, ReplyAs, Req},
	    loop(output(S, text(Req)));
	{candid_log, Kind, Text} ->
	    loop(lines(S, Kind, string:split(chars(Text), "\n", all)));
	toggle ->
	    loop(show(S, not maps:get(shown, S)));
	{show, On} ->
	    loop(show(S, On));
	Msg ->
	    case M:event(Pane, Msg) of
		close -> loop(show(S, false));
		clear -> pui(S, clear, []), loop(S#{n := 0});
		none  -> loop(S)
	    end
    end.

show(S, On) ->
    pui(S, show, [On]),
    S#{shown := On}.

%% io:format's output arrives in pieces; a line is shown when it is whole.
output(S, none) -> S;
output(S = #{part := P}, Text) ->
    case string:split(P ++ Text, "\n", all) of
	[Rest] -> S#{part := Rest};
	Ls ->
	    {Whole, [Rest]} = lists:split(length(Ls) - 1, Ls),
	    lines(S#{part := Rest}, io, Whole)
    end.

lines(S, Kind, Ls) ->
    lists:foldl(fun(L, Acc) -> line(Acc, Kind, string:trim(L, trailing)) end,
		S, Ls).

line(S, _Kind, "") -> S;
line(S = #{n := N}, Kind, L) ->
    pui(S, add, [kind(Kind, L), L]),
    case N + 1 > ?MAX of
	true  -> pui(S, trim, [?MAX div 10]), S#{n := N + 1 - ?MAX div 10};
	false -> S#{n := N + 1}
    end.

%% What colour a line gets: an error, a warning, csp's own, the rest.
kind(Kind, L) ->
    Low = string:lowercase(L),
    case {string:find(Low, "error"), string:find(Low, "fail")} of
	{nomatch, nomatch} ->
	    case {Kind, L} of
		{io, "panel: " ++ _} -> warning;
		{io, _}              -> note;
		_                    -> Kind
	    end;
	_ -> error
    end.

%% The text of an output request, none for anything else.
text({put_chars, Enc, Cs}) -> chars(Cs, Enc);
text({put_chars, Enc, M, F, A}) -> mfa(Enc, M, F, A);
text({put_chars, Cs}) -> chars(Cs, latin1);
text({put_chars, M, F, A}) -> mfa(latin1, M, F, A);
text({requests, Rs}) ->
    case [T || R <- Rs, T <- [text(R)], T =/= none] of
	[] -> none;
	Ts -> lists:append(Ts)
    end;
text(_) -> none.

mfa(Enc, M, F, A) ->
    try chars(apply(M, F, A), Enc) catch _:_ -> none end.

chars(Cs) -> chars(Cs, unicode).

chars(Cs, Enc) ->
    case unicode:characters_to_list(Cs, Enc) of
	L when is_list(L) -> L;
	_ -> lists:flatten(io_lib:format("~p", [Cs]))
    end.
