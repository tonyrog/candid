%%% A chat in the panel: a language model with the program, the manual, the
%%% compiler, varp and the running csp or node at hand, through ellm.
%%%
%%% Its own process, so it outlives the panel being rebuilt -- which `load'
%%% does, and so does connecting a node. Its pane hangs off document.body
%%% for the same reason: render/3 clears the panel's root.
%%%
%%% The model works on SOURCE TEXT, numbered: that is what it reads best, and
%%% `check' answers with the compiler's own file:line. No AST.
%%%
%%% What it may do. Read: the program, the values, the manual, the tree's
%%% .csp files. Write: only new files of its own, in the chat directory, and
%%% only a file it made this session may be written again. Drive: set, pause,
%%% step and resume, as the panel's buttons do -- on a NODE only when
%%% candid.config says {chat, [{node_control, true}]}, since a node may be
%%% wired to something that moves.
%%%
%%% candid.config: {ellm, [...]} is ellm's own configuration (backend, model,
%%% apikey -- see ellm's README), and {candid, [{chat, Opts}]} is ours:
%%%     {dir, Path}             where `load' writes (default: demo/)
%%%     {node_control, Bool}    may it drive a node (default false)
%%%     off                     no chat at all

-module(csp_chat).

-export([start/2, attach/2, toggle/1, available/0]).
-export([panel_tool/3]).                                % candid's half
-export([tools/0, manual/2, check/2, converse/3]).     % tests

-define(VARP_TIMEOUT, 60).
-define(MAX_READ, 60000).
-define(PANE, "position:fixed;top:0;right:0;bottom:0;width:38em;"
	"max-width:100vw;z-index:10;flex-direction:column;background:#1b1b1b;"
	"color:#ddd;border-left:1px solid #444;font:13px monospace;").

-define(SYSTEM, <<"You help write, understand and debug CandySpeak programs "
"in a live panel. CandySpeak is a rule language for small controllers: "
"declarations (#digital, #analog, #variable, #timer, #states, #module, "
"#buffer, #field, ...) and rules `body ? condition` that run every cycle and "
"read the values committed at the end of the previous cycle. Look things up "
"with the manual tool rather than guessing syntax, and check every program "
"you write with the check tool before you load it. Program text comes with "
"line numbers; errors come back as file:line. prove searches k steps and "
"then tries k-induction: `never' and `always hold' are proofs for all time, "
"`not within k steps' is not, and a "
"variable the model cannot translate is FREE, so a counterexample may be "
"spurious -- say so when it matters. Answer in the language the user writes "
"in, briefly.">>).

%%% ------------------------------------------------------------------ setup

%% ellm on the code path and not switched off.
available() ->
    code:which(ellm) =/= non_existing andalso
	candid_config() =/= off.

candid_config() ->
    _ = application:load(candid),
    case application:get_env(candid, chat) of
	{ok, V} -> V;
	undefined -> []
    end.

opt(Key, Def) ->
    case candid_config() of
	L when is_list(L) -> proplists:get_value(Key, L, Def);
	_ -> Def
    end.

%% One per panel connection, linked to it. Info: #{root, exe, demo_dir}.
start(Ws, Info) ->
    case available() of
	false -> undefined;
	true ->
	    Panel = self(),
	    spawn_link(fun() -> init(Ws, Panel, Info) end)
    end.

%% The panel was (re)built: what it shows now. Info: #{file, target, local}.
attach(undefined, _Info) -> ok;
attach(Chat, Info) -> Chat ! {attach, self(), Info}, ok.

toggle(undefined) -> ok;
toggle(Chat) -> Chat ! toggle, ok.

init(Ws, Panel, Info) ->
    Pane = pane(Ws),
    loop(#{ws => Ws, panel => Panel, pane => Pane, shown => false,
	   info => Info, msgs => [], worker => none, made => []}).

loop(S = #{ws := Ws, pane := Pane}) ->
    Send = maps:get(send, Pane),
    Close = maps:get(close, Pane),
    receive
	{attach, Panel, Info} ->
	    loop(S#{panel := Panel, info := maps:merge(maps:get(info, S), Info)});
	toggle ->
	    loop(show(S, not maps:get(shown, S)));
	{notify, Close, _, _} ->
	    loop(show(S, false));
	{notify, Send, _, Text0} ->
	    Text = string:trim(Text0),
	    case {Text, maps:get(worker, S)} of
		{"", _} -> loop(S);
		{_, none} ->
		    say(Ws, Pane, user, Text),
		    loop(ask(S, Text));
		_ ->
		    say(Ws, Pane, note, "busy -- wait for the answer"),
		    loop(S)
	    end;
	{chat_note, Text} ->
	    say(Ws, Pane, note, Text),
	    loop(S);
	{chat_made, File} ->
	    loop(S#{made := [File | maps:get(made, S)]});
	{chat_done, Msgs, New} ->
	    [say(Ws, Pane, assistant, C)
	     || #{role := assistant, content := C} <- New, C =/= <<>>],
	    busy(Ws, Pane, false),
	    loop(S#{msgs := Msgs, worker := none});
	{chat_error, Why} ->
	    say(Ws, Pane, error, io_lib:format("~p", [Why])),
	    busy(Ws, Pane, false),
	    loop(S#{worker := none});
	_ ->
	    loop(S)
    end.

show(S = #{ws := Ws, pane := #{box := Box}}, On) ->
    wse:setStyle(Ws, Box, ?PANE ++ case On of
				       true -> "display:flex";
				       false -> "display:none"
				   end),
    S#{shown := On}.

%%% -------------------------------------------------------------------- pane


pane(Ws) ->
    Box = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Box, ?PANE ++ "display:none"),
    Head = el(Ws, Box, "div", "display:flex;align-items:center;gap:8px;"
	      "padding:6px 8px;border-bottom:1px solid #333"),
    Title = el(Ws, Head, "span", "flex:1;color:#9cf"),
    wse:appendChild(Ws, Title, wse:createTextNode(Ws, "chat  " ++ model_name())),
    {ok, Close} = wse:create_event(Ws),
    X = el(Ws, Head, "button", "font:12px monospace"),
    wse:appendChild(Ws, X, wse:createTextNode(Ws, "close")),
    wse:set(Ws, X, "onclick", notify_f(Ws, Close, "'x'")),
    Log = el(Ws, Box, "div", "flex:1;overflow:auto;padding:8px;"
	     "white-space:pre-wrap;word-break:break-word"),
    Foot = el(Ws, Box, "div", "display:flex;gap:6px;padding:6px 8px;"
	      "border-top:1px solid #333"),
    In = el(Ws, Foot, "textarea", "flex:1;height:5em;resize:vertical;"
	    "font:13px monospace;background:#111;color:#eee;"
	    "border:1px solid #555;padding:4px"),
    wse:set(Ws, In, "placeholder", "Enter sends, shift+Enter is a new line"),
    {ok, Send} = wse:create_event(Ws),
    %% Enter sends and clears; shift+Enter is a line break.
    wse:set(Ws, In, "onkeydown",
	    wse:newf(Ws, "e", "{ if (e && e.key == 'Enter' && !e.shiftKey) {"
		     " e.preventDefault(); Wse.notify(" ++ integer_to_list(Send) ++
		     ", this.value); this.value = ''; } }")),
    Busy = el(Ws, Foot, "span", "color:#fb3;align-self:center;min-width:2em"),
    Attach = wse:newf(Ws, "e", "{ document.body.appendChild(e); }"),
    wse:cast(Ws, Attach, "call", [null, Box]),
    Scroll = wse:newf(Ws, "e", "{ e.scrollTop = e.scrollHeight; }"),
    #{box => Box, log => Log, input => In, send => Send, close => Close,
      busy => Busy, scroll => Scroll}.

el(Ws, Parent, Tag, Style) ->
    E = wse:createElement(Ws, Tag),
    wse:setStyle(Ws, E, Style),
    wse:appendChild(Ws, Parent, E),
    E.

notify_f(Ws, Id, Arg) ->
    wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++ ", " ++ Arg ++
		 "); }").

say(Ws, #{log := Log, scroll := Scroll}, Who, Text) ->
    Style = case Who of
		user -> "color:#9cf;margin:10px 0 4px";
		assistant -> "color:#eee;margin:4px 0";
		note -> "color:#888;margin:0";
		error -> "color:#f66;margin:4px 0"
	    end,
    D = el(Ws, Log, "div", Style),
    Prefix = case Who of user -> "> "; note -> "  · "; _ -> "" end,
    wse:appendChild(Ws, D, wse:createTextNode(
			     Ws, Prefix ++ unicode:characters_to_list(Text))),
    wse:cast(Ws, Scroll, "call", [null, Log]).

busy(Ws, #{busy := B}, On) ->
    wse:set(Ws, B, "textContent", case On of true -> "..."; false -> "" end).

model_name() ->
    try ellm:default_backend() of
	B when is_atom(B) -> atom_to_list(B);
	_ -> ""
    catch _:_ -> ""
    end.

%%% ------------------------------------------------------------------ asking

ask(S = #{ws := Ws, pane := Pane, msgs := Msgs0}, Text) ->
    busy(Ws, Pane, true),
    Chat = self(),
    Msgs = case Msgs0 of
	       [] -> [#{role => system, content => ?SYSTEM}];
	       _ -> Msgs0
	   end ++ [#{role => user,
		     content => unicode:characters_to_binary(Text)}],
    Ctx = #{chat => Chat, panel => maps:get(panel, S),
	    info => maps:get(info, S), made => maps:get(made, S)},
    W = spawn_link(
	  fun() ->
		  _ = ellm:start(),
		  try converse(Msgs, Ctx, #{}) of
		      {ok, All} ->
			  Chat ! {chat_done, All, lists:nthtail(length(Msgs), All)};
		      {error, Why} -> Chat ! {chat_error, Why}
		  catch C:Why -> Chat ! {chat_error, {C, Why}}
		  end
	  end),
    S#{worker := W}.

%% One turn: the model, the tools, until it stops asking for them. Ctx is
%% #{chat, panel, info, made}; Opts go to ellm (a test passes a backend).
converse(Msgs, Ctx, Opts) ->
    Handler = fun(Name, Args, St) -> tool(Name, Args, St) end,
    case ellm:run(Msgs, tools(), Handler, Ctx, Opts#{verbose => false}) of
	{ok, All, _} -> {ok, All};
	Error -> Error
    end.

%%% ------------------------------------------------------------------- tools

tools() ->
    [tool_def(<<"program">>,
	      <<"The program the panel shows, with line numbers, and where it "
		"runs (a local csp or a node). On a node it is the node's own "
		"program, listed off its image.">>, #{}, []),
     tool_def(<<"state">>,
	      <<"The values right now, by name, with the cycle and whether it "
		"runs or is paused.">>, #{}, []),
     tool_def(<<"manual">>,
	      <<"Search the CandySpeak manual. An empty query gives the table "
		"of contents.">>,
	      #{query => str(<<"words to look for, or a section title">>)}, []),
     tool_def(<<"read_file">>,
	      <<"Read a file of the CandySpeak tree: examples/, lib/, "
		"demo/, tests/unit/, boards/, doc/.">>,
	      #{path => str(<<"path from the tree's root, e.g. examples/traffic.csp">>)},
	      [<<"path">>]),
     tool_def(<<"list_files">>,
	      <<"The .csp files in one of the readable directories.">>,
	      #{dir => str(<<"e.g. examples or lib">>)}, [<<"dir">>]),
     tool_def(<<"check">>,
	      <<"Compile a program without running it. Answers ok, or the "
		"first error as file:line.">>,
	      #{source => str(<<"the whole program">>)}, [<<"source">>]),
     tool_def(<<"load">>,
	      <<"Check, then save as NAME.csp in the chat directory and run it "
		"in the panel. Only with a local target; never overwrites a "
		"file the chat did not make.">>,
	      #{name => str(<<"file name without .csp">>),
		source => str(<<"the whole program">>)},
	      [<<"name">>, <<"source">>]),
     tool_def(<<"edit">>,
	      <<"Change the program the panel shows by replacing OLD with NEW "
		"(OLD must occur exactly once), then load it as NAME.csp like "
		"load does. For a small change to a long program.">>,
	      #{name => str(<<"file name without .csp">>),
		old => str(<<"exact text to replace">>),
		new => str(<<"replacement">>)},
	      [<<"name">>, <<"old">>, <<"new">>]),
     tool_def(<<"prove">>,
	      <<"Ask varp about the program the panel shows. kind=invariants "
		"looks for a run breaking the program's `#annotate varp "
		"invariant' lines within k steps; kind=reach looks for a run "
		"reaching EXPR (a CandySpeak condition) within k steps. With "
		"no run found it tries to prove there never is one.">>,
	      #{kind => #{type => <<"string">>,
			  enum => [<<"invariants">>, <<"reach">>]},
		expr => str(<<"for reach: a condition, e.g. Red && Green">>),
		k => #{type => <<"integer">>,
		       description => <<"steps, default 10">>}},
	      [<<"kind">>]),
     tool_def(<<"set">>,
	      <<"Set an input or variable, as a widget does.">>,
	      #{name => str(<<"name, e.g. Btn or a.N">>),
		value => #{type => <<"integer">>}},
	      [<<"name">>, <<"value">>]),
     tool_def(<<"pause">>, <<"Stop the program, ready to step.">>, #{}, []),
     tool_def(<<"resume">>, <<"Let the program run again.">>, #{}, []),
     tool_def(<<"step">>, <<"Run N cycles while paused, then stop.">>,
	      #{n => #{type => <<"integer">>}}, [])].

tool_def(Name, Desc, Props, Req) ->
    #{name => Name, description => Desc,
      schema => #{type => <<"object">>, properties => Props, required => Req}}.

str(Desc) -> #{type => <<"string">>, description => Desc}.

%% The worker's half: what needs only files and programs runs here, what
%% needs the panel's state or its link is asked of the panel.
tool(Name, Args, Ctx = #{chat := Chat}) ->
    Chat ! {chat_note, note(Name, Args)},
    {Status, Text, Ctx1} = tool1(Name, Args, Ctx),
    case Status of
	error -> Chat ! {chat_note, ["  ", first_line(Text)]};
	ok -> ok
    end,
    {Status, Text, Ctx1}.

note(<<"check">>, _) -> "check";
note(<<"load">>, #{<<"name">> := N}) -> ["load ", N];
note(<<"edit">>, #{<<"name">> := N}) -> ["edit -> ", N];
note(<<"prove">>, A) -> ["prove ", maps:get(<<"kind">>, A, <<>>), " ",
			 maps:get(<<"expr">>, A, <<>>)];
note(Name, A) when map_size(A) =:= 0 -> Name;
note(Name, A) -> [Name, " ", io_lib:format("~0p", [maps:values(A)])].

first_line(T) -> hd(string:split(unicode:characters_to_list(T), "\n")).

tool1(<<"program">>, _, Ctx = #{info := Info}) ->
    File = maps:get(file, Info),
    case file:read_file(File) of
	{ok, Bin} ->
	    {ok, [io_lib:format("file: ~s~ntarget: ~s~n~n",
				[File, target_text(Info)]),
		  numbered(Bin)], Ctx};
	{error, Why} -> {error, io_lib:format("~s: ~p", [File, Why]), Ctx}
    end;
tool1(<<"manual">>, Args, Ctx = #{info := Info}) ->
    {ok, manual(maps:get(root, Info), maps:get(<<"query">>, Args, <<>>)), Ctx};
tool1(<<"read_file">>, #{<<"path">> := P}, Ctx = #{info := Info}) ->
    case readable(Info, P) of
	{ok, Full} ->
	    case file:read_file(Full) of
		{ok, Bin} when byte_size(Bin) =< ?MAX_READ -> {ok, numbered(Bin), Ctx};
		{ok, _} -> {error, "too large", Ctx};
		{error, Why} -> {error, io_lib:format("~p", [Why]), Ctx}
	    end;
	error -> {error, "not a readable file of the tree", Ctx}
    end;
tool1(<<"list_files">>, #{<<"dir">> := D}, Ctx = #{info := Info}) ->
    case readable_dir(Info, D) of
	{ok, Full} ->
	    Fs = filelib:wildcard("*.csp", Full),
	    {ok, lists:join("\n", Fs), Ctx};
	error -> {error, "not a readable directory", Ctx}
    end;
tool1(<<"check">>, #{<<"source">> := Src}, Ctx = #{info := Info}) ->
    case check(Info, Src) of
	ok -> {ok, "ok", Ctx};
	{error, Why} -> {error, Why, Ctx}
    end;
tool1(<<"load">>, #{<<"name">> := N, <<"source">> := Src}, Ctx) ->
    load(N, Src, Ctx);
tool1(<<"edit">>, #{<<"name">> := N, <<"old">> := Old, <<"new">> := New},
      Ctx = #{info := Info}) ->
    {ok, Bin} = file:read_file(maps:get(file, Info)),
    case binary:matches(Bin, Old) of
	[_] -> load(N, binary:replace(Bin, Old, New), Ctx);
	[] -> {error, "OLD does not occur in the program", Ctx};
	_ -> {error, "OLD occurs more than once; give more of the text", Ctx}
    end;
tool1(<<"prove">>, Args, Ctx = #{info := Info}) ->
    {ok, prove(maps:get(file, Info), Args), Ctx};
tool1(Name, Args, Ctx = #{panel := Panel}) ->
    Ref = make_ref(),
    Panel ! {chat_tool, self(), Ref, Name, Args},
    receive
	{Ref, {Status, Text}} -> {Status, Text, Ctx}
    after 10000 -> {error, "the panel did not answer", Ctx}
    end.

target_text(#{target := T}) when T =/= "" -> T;
target_text(_) -> "local".

numbered(Bin) ->
    Ls = string:split(unicode:characters_to_list(Bin), "\n", all),
    [io_lib:format("~4w  ~ts~n", [N, L])
     || {N, L} <- lists:zip(lists:seq(1, length(Ls)), Ls)].

%%% A file of the tree, never outside it, and only of the readable kinds.
-define(READ_DIRS, ["examples", "lib", "demo", "tests/unit",
		    "boards", "doc"]).

readable(Info, P0) ->
    P = unicode:characters_to_list(P0),
    Ok = lists:member(filename:extension(P), [".csp", ".md", ".terms"])
	andalso not lists:member("..", filename:split(P))
	andalso lists:any(fun(D) -> lists:prefix(D ++ "/", P) end, ?READ_DIRS),
    case Ok of
	true -> {ok, full(Info, P)};
	false -> error
    end.

readable_dir(Info, D0) ->
    D = string:trim(unicode:characters_to_list(D0), trailing, "/"),
    Under = lists:member(D, ?READ_DIRS) orelse
	lists:any(fun(R) -> lists:prefix(R ++ "/", D) end, ?READ_DIRS),
    case Under andalso not lists:member("..", filename:split(D)) of
	true -> {ok, full(Info, D)};
	false -> error
    end.

%% demo/ is candid's own, the rest is candyspeak's tree.
full(Info, P) ->
    case filename:split(P) of
	["demo" | Rest] -> filename:join([maps:get(demo_dir, Info) | Rest]);
	_ -> filename:join(maps:get(root, Info), P)
    end.

%%% --------------------------------------------------------------- compiling

%% The compiler's word: csp loads the program and stops; an error is the
%% first line it prints, as file:line. The panel's own parser has to take it
%% too, or the panel cannot be built from it.
check(Info, Src) ->
    Dir = scratch(),
    File = filename:join(Dir, "check_" ++
			     integer_to_list(erlang:unique_integer([positive])) ++
			     ".csp"),
    ok = file:write_file(File, Src),
    try check_file(Info, File)
    after file:delete(File)
    end.

check_file(Info, File) ->
    Exe = maps:get(exe, Info),
    Db = filename:join(scratch(), "check.db"),
    Out = os:cmd("printf '/quit\\n' | " ++ Exe ++ " -i --no-eeprom -e " ++ Db ++
		     " -c 0 " ++ File ++ " 2>&1"),
    Errors = [L || L <- string:split(Out, "\n", all),
		   string:find(L, File ++ ":") =/= nomatch],
    case Errors of
	[] ->
	    case candyspeak:parse(File) of
		{ok, _} -> ok;
		Error -> {error, io_lib:format("the panel cannot read it: ~p",
					       [Error])}
	    end;
	_ ->
	    {error, lists:join("\n", [string:replace(L, File, "program")
				      || L <- Errors])}
    end.

scratch() ->
    D = filename:join(os:getenv("TMPDIR", "/tmp"), "csp_chat"),
    ok = filelib:ensure_dir(filename:join(D, "x")),
    D.

load(Name0, Src, Ctx = #{info := Info, chat := Chat, made := Made}) ->
    Name = unicode:characters_to_list(Name0),
    Dir = opt(dir, maps:get(demo_dir, Info)),
    File = filename:join(Dir, Name ++ ".csp"),
    Safe = Name =/= "" andalso
	lists:all(fun(C) -> C =:= $_ orelse C =:= $- orelse
				(C >= $a andalso C =< $z) orelse
				(C >= $A andalso C =< $Z) orelse
				(C >= $0 andalso C =< $9) end, Name),
    Ours = not filelib:is_regular(File) orelse lists:member(File, Made),
    case {Safe, Ours, maps:get(local, Info, true)} of
	{false, _, _} -> {error, "a name of letters, digits, - and _", Ctx};
	{_, false, _} -> {error, [File, " exists and is not the chat's; "
				  "pick another name"], Ctx};
	{_, _, false} -> {error, "the panel runs a node: loading needs a local "
			  "target (the user types `local' in the target field)",
			  Ctx};
	_ ->
	    case check(Info, Src) of
		{error, Why} -> {error, Why, Ctx};
		ok ->
		    ok = file:write_file(File, Src),
		    Chat ! {chat_made, File},
		    Ctx1 = Ctx#{made := [File | Made],
				info := Info#{file := File}},
		    {S, T, _} = tool1(<<"load_file">>,
				      #{<<"file">> => list_to_binary(File)}, Ctx1),
		    {S, T, Ctx1}
	    end
    end.

%%% ------------------------------------------------------------------ proofs

prove(File, Args) ->
    K = case maps:get(<<"k">>, Args, 10) of
	    N when is_integer(N), N > 0, N =< 100 -> N;
	    _ -> 10
	end,
    Kind = maps:get(<<"kind">>, Args, <<"invariants">>),
    Opts = case Kind of
	       <<"reach">> ->
		   [{reach, unicode:characters_to_list(
			      maps:get(<<"expr">>, Args, <<>>))}];
	       _ -> []
	   end,
    case {candyspeak_varp:model(File, Opts), varp_sh()} of
	{_, none} -> "varp not found: set VARP_SH to its varp.sh";
	{{ok, M = #{name := Name}}, Sh} ->
	    Prop = case Kind of
		       <<"reach">> -> "--property " ++ Name ++ "_reach";
		       _ -> ""
		   end,
	    R = candyspeak_varp:prove(M, Prop, K, ?VARP_TIMEOUT, Sh),
	    [answer(Kind, K, R), free(M)];
	{Error, _} ->
	    why(Error)
    end.

why({error, {varp_annotate, _Loc, _Kind, {not_modelled, _T, Names}}}) ->
    ["the model has nothing called ", lists:join(", ", Names),
     " -- use the program's own names"];
why({error, {instances_not_modelled, Ms}}) ->
    ["no #module for ", lists:join(", ", Ms)];
why(Error) ->
    io_lib:format("not modelled: ~p", [Error]).

answer(_, _K, no_transitions) ->
    "the model has NO transitions, so nothing can be said: every question "
	"would come back unreachable";
answer(<<"reach">>, _K, {proved, 0}) ->
    "never: no step can lead into it, whatever state came before "
	"(proved by 0-induction -- the rules alone rule it out)";
answer(<<"reach">>, _K, {proved, N}) ->
    io_lib:format("never: no run reaches it (proved by ~w-induction -- it "
		  "takes the history of ~w steps to rule it out)", [N, N]);
answer(<<"reach">>, K, {none, _}) ->
    io_lib:format("not reachable within ~w steps, but not proved for ever "
		  "either: a longer run may get there", [K]);
answer(_, _K, {proved, N}) ->
    io_lib:format("the invariants always hold, in every run "
		  "(proved by ~w-induction)", [N]);
answer(<<"reach">>, _K, {found, At, Rows}) ->
    [io_lib:format("reached at step ~w. The run:~n", [At]), rows(Rows)];
answer(_, K, {none, _}) ->
    io_lib:format("no run breaks the invariants within ~w steps, but they "
		  "are not proved for ever: a longer run may", [K]);
answer(_, _K, {found, At, Rows}) ->
    [io_lib:format("an invariant breaks at step ~w. The run:~n", [At]),
     rows(Rows)];
answer(_, _K, {error, Out}) ->
    ["varp: ", Out];
answer(_, _K, Other) ->
    io_lib:format("~p", [Other]).

%% Each step's values, and after the first only what changed.
rows(Rows) ->
    {Lines, _} =
	lists:mapfoldl(
	  fun(R, {I, Prev}) ->
		  Ch = [{N, V} || {N, V} <- R, maps:get(N, Prev, x) =/= V],
		  {io_lib:format("  step ~w: ~s~n",
				 [I, lists:join(" ", [[to_s(N), "=", to_s(V)]
						      || {N, V} <- Ch])]),
		   {I + 1, maps:merge(Prev, maps:from_list(R))}}
	  end, {0, #{}}, Rows),
    Lines.

to_s(V) when is_integer(V) -> integer_to_list(V);
to_s(V) when is_atom(V) -> atom_to_list(V);
to_s(V) -> io_lib:format("~ts", [V]).

%% What the model left free: a counterexample through one of these may be
%% one the program cannot take.
free(M) ->
    case [N || {N, _} <- maps:get(abstracted, M, [])] ++
	maps:get(free, M, []) of
	[] -> "";
	Fs -> io_lib:format("~nleft free in the model: ~p", [Fs])
    end.

varp_sh() ->
    F = case os:getenv("VARP_SH") of
	    false -> filename:join(os:getenv("HOME"), "erlang/varp/priv/varp.sh");
	    Sh -> Sh
	end,
    case filelib:is_regular(F) of
	true -> F;
	false -> none
    end.

%%% ------------------------------------------------------------------ manual

%% The manual's sections that say the most about the query, or its table of
%% contents.
manual(Root, Query) ->
    {ok, Bin} = file:read_file(filename:join(Root, "doc/manual_en.md")),
    Secs = sections(binary_to_list(Bin)),
    case string:lexemes(string:lowercase(unicode:characters_to_list(Query)),
			" ") of
	[] -> lists:join("\n", [T || {T, _} <- Secs]);
	Words ->
	    Scored = lists:reverse(lists:sort(
				     [{score(Words, T, B), T, B} || {T, B} <- Secs])),
	    case [{T, B} || {Sc, T, B} <- lists:sublist(Scored, 3), Sc > 0] of
		[] -> "nothing found; try fewer or other words";
		Top -> [[T, "\n", string:slice(B, 0, 4000), "\n\n"] || {T, B} <- Top]
	    end
    end.

sections(Text) ->
    sections(string:split(Text, "\n", all), "", [], []).

sections([L = "#" ++ _ | Ls], T, B, Acc) ->
    sections(Ls, L, [], add(T, B, Acc));
sections([L | Ls], T, B, Acc) ->
    sections(Ls, T, [L | B], Acc);
sections([], T, B, Acc) ->
    lists:reverse(add(T, B, Acc)).

add("", _, Acc) -> Acc;
add(T, B, Acc) -> [{T, lists:flatten(lists:join("\n", lists:reverse(B)))} | Acc].

score(Words, T, B) ->
    Tl = string:lowercase(T),
    Bl = string:lowercase(B),
    lists:sum([10 * count(W, Tl) + count(W, Bl) || W <- Words]).

count(W, S) -> length(string:split(S, W, all)) - 1.

%%% ---------------------------------------------------------- panel's half

%% What only the panel can do: read its values and drive its link. Info is
%% #{last, clock, mode, local, link}. Returns {Status, Text}; or {load, File,
%% Reply} and {control, Tag, Reply}, which the panel acts on as it would on
%% its own chooser and buttons, so they show what happened.
panel_tool(<<"state">>, _, #{last := Last, clock := {Cycle, _}, mode := Mode}) ->
    {ok, [io_lib:format("cycle ~p, ~s~n", [Cycle, case Mode of
						     run -> "running";
						     step -> "paused"
						 end]),
	  [io_lib:format("~s = ~p~n", [N, V])
	   || {N, V} <- lists:sort(maps:to_list(Last))]]};
panel_tool(<<"load_file">>, #{<<"file">> := F}, _) ->
    {load, binary_to_list(F), {ok, "loaded and running in the panel"}};
panel_tool(Name, Args, I) ->
    case maps:get(local, I) orelse opt(node_control, false) of
	false -> {error, "the panel runs a node, and candid.config does not let "
		  "the chat drive one ({chat, [{node_control, true}]})"};
	true -> drive(Name, Args, I)
    end.

drive(<<"set">>, #{<<"name">> := N, <<"value">> := V}, #{link := Link}) ->
    csp_link:set(Link, unicode:characters_to_list(N), V),
    {ok, "set"};
drive(<<"pause">>, _, _) -> {control, "mode=step", {ok, "paused"}};
drive(<<"resume">>, _, _) -> {control, "mode=run", {ok, "running"}};
drive(<<"step">>, _, #{mode := run}) ->
    {error, "the program runs; pause it first"};
drive(<<"step">>, Args, #{link := Link}) ->
    N = case maps:get(<<"n">>, Args, 1) of
	    I when is_integer(I), I > 0, I =< 10000 -> I;
	    _ -> 1
	end,
    csp_link:step(Link, N),
    {ok, io_lib:format("stepped ~w", [N])};
drive(Name, _, _) ->
    {error, ["no such tool: ", Name]}.
