%% A backend for ellm that needs no network: it asks for the program, then
%% has a line of it checked, then says what check answered. Enough to run
%% csp_chat's tool loop end to end.
-module(fake_llm).
-export([chat/2, list_models/1]).

chat(Msgs, _Opts) ->
    case lists:last(Msgs) of
	#{role := user} ->
	    call(<<"1">>, <<"program">>, #{});
	#{role := tool, tool_call_id := <<"1">>, content := _Prog} ->

	    call(<<"2">>, <<"check">>,
		 #{<<"source">> => <<"#digital Led out 0:13\nLed = 1\n">>});
	#{role := tool, tool_call_id := <<"2">>, content := C} ->
	    {ok, #{message => #{role => assistant,
				content => <<"check said: ", C/binary>>},
		   stop => stop}}
    end.

list_models(_) -> {ok, []}.

call(Id, Name, Args) ->
    {ok, #{message => #{role => assistant, content => <<>>,
			tool_calls => [#{id => Id, name => Name,
					 arguments => Args}]},
	   stop => tool_calls}}.

