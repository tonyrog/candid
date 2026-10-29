%%% The code view: the program's rules, lit by what holds.
%%%
%%% Two renderings of the same tree. CODE is candyspeak as written (re-printed
%%% from the parse tree, so comments and layout are gone). LADDER draws each
%%% guard the way Sternol did: an AND runs HORIZONTALLY, a chain of contacts
%%% the current passes through one after the other, and an OR stacks its
%%% branches VERTICALLY between two rails. The assignments are the coil at
%%% the end of the rung.
%%%
%%% A contact -- any sub-condition that is not && || or a ! over one -- is lit
%%% when it holds in the CURRENT state, so setting an input lights what it
%%% enables at once, before the step that acts on it. candyspeak_eval works it
%%% out from the dump; what the dump cannot say (a timer, a buffer byte) is
%%% drawn dashed, never guessed.
%%%
%%% The coil is lit when csp says the rule FIRED in the last cycle (--fired),
%%% which is the runtime's word, not ours. Outlined when its guard holds now:
%%% it will fire on the next step unless its block is not the active one.
%%%
%%% An unguarded `X = <condition>' is a rung of its own -- the classic ladder
%%% line, contacts driving an output -- so the condition is drawn as the
%%% contacts and X alone as the coil, lit when X is on. It fires every cycle,
%%% so lighting it for that would say nothing.
%%%
%%% Rules are numbered as csp numbers them -- the Nth rule in the source, the
%%% number #disable and the listing use -- and a #timer whose period is not a
%%% constant compiles to a rule of its own, `T.period = P', at its
%%% declaration.
%%%
%%% TABS. `main' is the program outside its #module definitions; every object
%%% gets a tab of its own with its module's rules, evaluated over THAT
%%% object's values (`a0.A' read as `A'), and its bindings above them. Each
%%% tab starts with the values the panel has no widget for: the variables and
%%% the #locals, worked out.
%%%
%%% MARKS. A click on a contact says it should hold, the next that it should
%%% not, the third forgets it. The marks add up to one condition, the GOAL,
%%% shown in the panel's top frame, and `solve' asks varp whether some run of
%%% the program gets there within k steps, and when none does, whether one
%%% ever can: k-induction proves `never' (candyspeak_varp:model/2, prove/5).
%%% `clear' drops the marks and checks the model itself: that it has
%%% transitions at all, and what it leaves free. A signal is marked the same
%%% way, by its label among the devices or its cell among the values: `Siren'
%%% (it is on) for one bit, `N == 5' (its value now) for more.
%%%
%%% REPLAY. A trace varp found is played back on the running csp: reset, then
%%% per step the trace's inputs are set and one step is run. The column of the
%%% step is lit, and a value csp disagrees with is red -- which is what a trace
%%% through a guard the model could not read (L26?) looks like when the real
%%% timer did not run out. What the view cannot do itself, it leaves in
%%% `acts' for the panel to send to csp (actions/1).
%%%
%%% csp says which rules fired as {Object, File, Line} (--fired): a module's
%%% rule is one piece of code run once per instance, so the object says whose
%%% tab lights it, and file and line say which rung. A rule that fires for one
%%% cycle -- a timeout -- would light for one tick and be missed, so a coil
%%% stays lit for ?GLOW ms after it last fired; tick/2 lets it go out.

-module(csp_code).

-export([new/4, refresh/3, fired/3, tick/2, control/3, model/3, actions/1]).
-export([goal_text/1, contact_of/3, state_name/2, sig_expr/2,
	 look_values/1, look_text/1]).                   % tests
-export([split/1]).
-export([rules/1, tabs/1, tabs/2]).                  % tests

-define(GLOW, 600).                     % ms a coil stays lit after firing
-define(KS, [1, 2, 5, 10, 20, 50]).     % solve's bounds, k steps from INIT
-define(K, 10).
-define(VARP_TIMEOUT, 30).              % s; long runs belong on the big box

%% The highlights, settable from candid.config ({colors, [{true, "#3f3"}]}).
%% Any css colour. The fill and the text are mixed from it, so one colour is
%% the whole look of a lit contact.
-define(COLOURS, #{true => "#3f3",          % a contact that holds now
		   fired => "#fb3",         % a coil whose rule fired
		   next => "#fb3",          % outline: the guard holds now
		   block => "#bdf",         % the #in / #when block in force
		   want => "#4af",          % marked: should hold
		   unwant => "#f55"}).      % marked: should not

colours(Cfg) -> maps:merge(?COLOURS, maps:with(maps:keys(?COLOURS), Cfg)).

css(C) ->
    Fill = fun(K) -> ["color-mix(in srgb,", maps:get(K, C), " 25%,#111)"] end,
    Ink = fun(K) -> ["color-mix(in srgb,", maps:get(K, C), " 35%,#fff)"] end,
    Col = fun(K) -> maps:get(K, C) end,
    lists:flatten(
      [".cv{font:13px monospace;color:#bbb}"
       ".cv .bar button{font:12px monospace;padding:2px 8px;margin:0 4px 8px 0;"
       "  border:1px solid #555;background:#333;color:#ccc}"
       ".cv .bar button.sel{background:#3af;color:#111;font-weight:bold}"
       %% A table: the cells share their borders, one line between two.
       ".vals{display:grid;grid-template-columns:repeat(auto-fill,"
       "  minmax(150px,1fr));margin:0 1px 10px 0;color:#888;"
       "  font:13px monospace}"
       ".vals span{border:1px solid #3a3a3a;margin:0 -1px -1px 0;"
       "  padding:2px 8px}"
       ".vals b{color:#ddd;font-weight:normal;float:right}"
       ".vals i{color:#8ab}"
       %% The model frame, in the panel's top: goal, solve, the answer.
       ".md{font:13px monospace;color:#bbb}"
       ".md button,.md select{font:12px monospace;padding:2px 8px;"
       "  margin-left:4px;border:1px solid #555;background:#333;color:#ccc}"
       ".md .goal{display:inline-block;min-width:320px;padding:3px 10px;"
       "  border:2px solid ", Col(want), ";border-radius:3px;color:#eee;"
       "  background:", Fill(want), "}"
       ".md .goal.none{border-style:dashed;color:#888;background:none}"
       ".md .res{margin:6px 0 4px 0;white-space:pre-wrap;color:#aaa;"
       "  max-height:30vh;overflow:auto}"
       ".md .res.bad{color:", Col(unwant), "}"
       ".md .res.ok{color:", Col(true), "}"
       ".md table{border-collapse:collapse;margin:2px 0 8px 0}"
       ".md td,.md th{border:1px solid #3a3a3a;padding:1px 8px;"
       "  text-align:right}"
       ".md th{color:#8ab;font-weight:normal}"
       ".md td.g{color:", Col(want), "}"
       ".md td.any{color:#555}"
       ".md .hid{display:none}"
       ".md td.cur,.md th.cur{background:", Fill(want), "}"
       ".md td.bad{background:", Fill(unwant), ";color:", Ink(unwant), "}"
       "[data-sig]{cursor:pointer}"
       ".sgt{outline:2px solid ", Col(want), ";outline-offset:1px}"
       ".sgf{outline:2px dashed ", Col(unwant), ";outline-offset:1px}"
       ".cv .bind{color:#8ab;margin-bottom:8px}"
       ".cv .rw{display:flex;align-items:center;margin:3px 0;flex-wrap:nowrap}"
       ".cv .ln{color:#555;width:3.2em;text-align:right;margin-right:10px;"
       "  flex:none}"
       ".cv .and{display:flex;align-items:center}"
       ".cv .or{display:flex;flex-direction:column;border-left:2px solid #666;"
       "  border-right:2px solid #666;padding:1px 0}"
       ".cv .br{display:flex;align-items:center;justify-content:space-between}"
       ".cv .br>.w:last-child{flex:1}"
       ".cv .w{display:inline-block;height:2px;min-width:10px;background:#666}"
       ".cv .ct{border:1px solid #555;padding:1px 6px;border-radius:3px;"
       "  background:#1e1e1e;color:#999;white-space:nowrap;cursor:pointer}"
       ".cv .ct.t{background:", Fill(true), ";border-color:", Col(true),
       ";color:", Ink(true), ";box-shadow:0 0 6px ", Col(true), "}"
       ".cv .ct.u{border-style:dashed;color:#666}"
       %% A mark is the frame: the fill still says what holds now.
       ".cv .ct.mt{outline:2px solid ", Col(want), ";outline-offset:2px}"
       ".cv .ct.mf{outline:2px dashed ", Col(unwant), ";outline-offset:2px}"
       ".cv .co{border:1px solid #555;border-radius:10px;padding:1px 9px;"
       "  color:#999;white-space:nowrap}"
       ".cv .co.nx{border-color:", Col(next), ";color:", Ink(next), "}"
       ".cv .co.on{background:", Fill(fired), ";border-color:", Col(fired),
       ";color:", Ink(fired), ";box-shadow:0 0 7px ", Col(fired), "}"
       ".cv .hd{color:#68a;margin:10px 0 2px 0}"
       ".cv .rw.off{opacity:0.35}"
       ".cv .hd.e{color:#456;margin:2px 0 8px 0}"
       ".cv .hd.t{color:", Col(block), ";font-weight:bold}"
       ".cv.code .ct{border:none;padding:0 2px;background:none;box-shadow:none}"
       ".cv.code .ct.t{color:", Col(true), ";text-shadow:0 0 5px ", Col(true), "}"
       ".cv.code .ct.u{color:#666;text-decoration:underline dotted}"
       ".cv.code .co{border:none;padding:0 2px}"
       ".cv.code .co.on{background:", Fill(fired), "}"
       ".cv.code .op{color:#777}"
       ".cv .tx{white-space:pre}"]).

%%% ------------------------------------------------------------- the rules

%% [{gate, Kind, Arg} | #{no, line, file, guard, assigns, gates}] in source
%% order. `gates' is every block the rule sits in; a rule in none runs in INIT
%% and NORMAL only, as csp has it. `file' is the basename of the file the rule
%% is written in: candyspeak:parse/2 with `sources' marks where an imported
%% file starts and ends, and Top is the file the walk starts in.
rules(Ast) -> rules(Ast, "").

rules(Ast, Top) ->
    number(walk(Ast, #{cs => consts(Ast), gs => [],
		       file => filename:basename(Top)}), 1).

%% One tab per object, after `main'. #{name, rules, env, prefix, vars, binds}.
tabs(Ast) -> tabs(Ast, "").

tabs(Ast, Top) ->
    {Main, Mods} = split(Ast),
    GEnv = candyspeak_eval:env(Main),
    [#{name => "main", rules => rules(Main, Top), env => GEnv, prefix => none,
       vars => vars(Main), binds => none}] ++
	[#{name => O, rules => rules(Body, Top), prefix => O, vars => vars(Body),
	   env => merge_env(GEnv, candyspeak_eval:env(Body)),
	   own => own(candyspeak_eval:env(Body)), binds => {M, Bs}}
	 || {object, _, {'WORD', _, M}, {'WORD', _, O}, Bs} <- Main,
	    {ok, Body} <- [maps:find(M, Mods)]].

%% The program outside its #module definitions, and each definition's body.
%% A module ends at the #end that closes it, not at one closing an #in in it.
%% A body starts with the {source, 0, File} it was written in, when it was
%% not the top file, so the rules in it know where they are.
split(Ast) -> split(Ast, [], #{}, undefined).

split([{module, _, {'WORD', _, M}} | T], Acc, Mods, F) ->
    {Body, Rest} = body(T, 0, []),
    split(Rest, Acc, Mods#{M => src(F) ++ Body}, F);
split([{module, _, {'WORD', _, M}, _} | T], Acc, Mods, F) ->
    {Body, Rest} = body(T, 0, []),
    split(Rest, Acc, Mods#{M => src(F) ++ Body}, F);
split([X = {source, _, F} | T], Acc, Mods, _F) -> split(T, [X | Acc], Mods, F);
split([X | T], Acc, Mods, F) -> split(T, [X | Acc], Mods, F);
split([], Acc, Mods, _F) -> {lists:reverse(Acc), Mods}.

src(undefined) -> [];
src(F)         -> [{source, 0, F}].

body([{'end', _} | T], 0, Acc) -> {lists:reverse(Acc), T};
body([X = {'end', _} | T], D, Acc) -> body(T, D - 1, [X | Acc]);
body([X = {in, _, _} | T], D, Acc) -> body(T, D + 1, [X | Acc]);
body([X = {'when', _, _} | T], D, Acc) -> body(T, D + 1, [X | Acc]);
body([X | T], D, Acc) -> body(T, D, [X | Acc]);
body([], _D, Acc) -> {lists:reverse(Acc), []}.

%% The names an object has of its own: `A' in a0's tab is `a0.A' outside it.
own(#{sigs := S, locals := L}) -> maps:keys(S) ++ maps:keys(L).

merge_env(G, M) ->
    maps:map(fun(states, V) -> maps:get(states, G) ++ V;
		(K, V)      -> maps:merge(maps:get(K, G), V)
	     end, M).

%% The values a tab lists: variables, and #locals marked as worked out.
vars(Ast) ->
    [{var, N} || {variable, _, {'WORD', _, N}, scalar, _, _, _} <- Ast] ++
	[{local, N} || {local, _, {'WORD', _, N}, _, _, X} <- Ast,
		       X =/= undefined].

walk([{source, _, F} | T], C) ->
    walk(T, C#{file := filename:basename(F)});
walk([{in, _, Names} | T], C = #{gs := Gs}) ->
    G = {in, [N || {'WORD', _, N} <- Names]},
    [{gate, in, element(2, G)} | walk(T, C#{gs := [G | Gs]})];
walk([{'when', _, X} | T], C = #{gs := Gs}) ->
    [{gate, 'when', X} | walk(T, C#{gs := [{'when', X} | Gs]})];
walk([{'end', _} | T], C = #{gs := Gs}) ->
    [{gate, 'end', none} | walk(T, C#{gs := tl_or_nil(Gs)})];
walk([{rule, _, _, _} = R | T], C = #{gs := Gs, file := F}) ->
    [M#{file => F,
	gates => case Gs of
		     [] -> [{in, ["INIT", "NORMAL"]}];
		     _  -> Gs
		 end} || M <- rule(R)] ++ walk(T, C);
walk([{timer, Ln, {'WORD', _, N}, P, _} | T], C = #{cs := Cs, file := F}) ->
    case period_rule(P, Cs) of
	true ->
	    Tgt = {field, Ln, {part, Ln, {'WORD', Ln, N}, {'WORD', Ln, "period"}}},
	    [#{line => Ln, file => F, guard => undefined, gates => [],
	       assigns => [{'=', Ln, Tgt, P}]} | walk(T, C)];
	false -> walk(T, C)
    end;
walk([_ | T], C) -> walk(T, C);
walk([], _C) -> [].

tl_or_nil([_ | T]) -> T;
tl_or_nil([])      -> [].

rule({rule, Ln, As = [{'=', _, Tgt, X}], undefined}) ->
    case is_cond(X) of
	true  -> [#{line => Ln, guard => X, assigns => As, coil => Tgt}];
	false -> [#{line => Ln, guard => undefined, assigns => As}]
    end;
rule({rule, Ln, As, G}) ->
    [#{line => Ln, guard => guard(G), assigns => As}].


is_cond({Op, _, _, _}) ->
    lists:member(Op, ['&&', '||', '==', '!=', '<', '<=', '>', '>=']);
is_cond({'!', _, _}) -> true;
is_cond(_) -> false.

%% `true' is what the parser gives a pack/unpack rule; it is no guard.
guard(true) -> undefined;
guard(G)    -> G.

%% A literal or a #constant/#define folds; anything else is computed at run
%% time, by a rule.
period_rule({'INT', _, _}, _Cs) -> false;
period_rule({field, _, {'WORD', _, N}}, Cs) -> not lists:member(N, Cs);
period_rule(_, _Cs) -> true.

consts(Ast) ->
    [N || {constant, _, {'WORD', _, N}, _, _, _, _} <- Ast] ++
	[N || {define, _, {'WORD', _, N}, _} <- Ast].

number([R = #{} | T], N) -> [R#{no => N} | number(T, N + 1)];
number([G | T], N)       -> [G | number(T, N)];
number([], _N)           -> [].

%%% ----------------------------------------------------------------- view

%% Hidden until control/3 says ladder or code. Ast is candyspeak:parse/2 of
%% File with `sources'; Cfg is candid.config's say, today the colours.
%%
%% Where: #{code => the code view's column, status => the top frame's row of
%% boxes (the goal and solve go there), top => the top frame below it (the
%% answer and the program's values)}.
new(Ws, Where, {Ast, File}, Cfg) ->
    #{code := Parent, status := Row, top := Top} = Where,
    Style = wse:createElement(Ws, "style"),
    wse:set(Ws, Style, "textContent", css(colours(Cfg))),
    wse:appendChild(Ws, Parent, Style),
    {ok, Ev} = wse:create_event(Ws),
    Notify = fun(Tag) -> wse:newf(Ws, "", "{ Wse.notify(" ++
				      integer_to_list(Ev) ++ ", " ++ Tag ++
				      "); }")
	     end,
    Box = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Box, "display:none"),
    Tabs = tabs(Ast, File),
    Bar = wse:createElement(Ws, "div"),
    wse:set(Ws, Bar, "className", "bar"),
    Btns = case Tabs of
	       [_] -> [];
	       _ ->
		   [begin
			B = wse:createElement(Ws, "button"),
			wse:appendChild(Ws, B, wse:createTextNode(Ws, Name)),
			wse:set(Ws, B, "onclick",
				Notify("'tab=" ++ integer_to_list(I) ++ "'")),
			wse:appendChild(Ws, Bar, B),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    Body = wse:createElement(Ws, "div"),
    wse:appendChild(Ws, Box, Bar),
    wse:appendChild(Ws, Box, Body),
    wse:appendChild(Ws, Parent, Box),
    %% The model frame: goal, clear, solve within k, and below them the answer
    %% and the values.
    Md = wse:createElement(Ws, "span"),
    wse:set(Ws, Md, "className", "md"),
    Goal = wse:createElement(Ws, "span"),
    wse:appendChild(Ws, Md, Goal),
    [begin
	 B = wse:createElement(Ws, "button"),
	 wse:appendChild(Ws, B, wse:createTextNode(Ws, Label)),
	 wse:set(Ws, B, "onclick", Notify("'" ++ Label ++ "'")),
	 wse:appendChild(Ws, Md, B)
     end || Label <- ["clear", "solve"]],
    Sel = wse:createElement(Ws, "select"),
    [begin
	 O = wse:createElement(Ws, "option"),
	 wse:set(Ws, O, "value", K),
	 wse:appendChild(Ws, O, wse:createTextNode(
				  Ws, "k \x{2264} " ++ integer_to_list(K))),
	 K =:= ?K andalso wse:set(Ws, O, "selected", true),
	 wse:appendChild(Ws, Sel, O)
     end || K <- ?KS],
    wse:set(Ws, Sel, "onchange", Notify("'k=' + this.value")),
    wse:appendChild(Ws, Md, Sel),
    wse:appendChild(Ws, Row, Md),
    Res = wse:createElement(Ws, "div"),
    wse:set(Ws, Res, "className", "md"),
    wse:appendChild(Ws, Top, Res),
    #{vars := MainVars} = hd(Tabs),
    Vals = wse:createElement(Ws, "div"),
    wse:set(Ws, Vals, "innerHTML", lists:flatten(vals("m_", none, MainVars))),
    wse:appendChild(Ws, Top, Vals),
    Paint = wse:newf(Ws, "a,b",
		     "{ for (var i = 0; i < a.length; i += 2) {"
		     "    var e = document.getElementById(a[i]);"
		     "    if (e) e.className = a[i+1]; }"
		     "  for (var i = 0; i < b.length; i += 2) {"
		     "    var e = document.getElementById(b[i]);"
		     "    if (e) e.textContent = b[i+1]; } }"),
    %% Any element with data-sig is a signal to mark: the devices' labels and
    %% the value cells. One handler on the panel, since the cells come and go
    %% with the tabs.
    Sig = wse:newf(Ws, "",
		   "{ document.getElementById('panel').onclick = function(e) {"
		   "    var t = e.target.closest('[data-sig]');"
		   "    if (t) Wse.notify(" ++ integer_to_list(Ev) ++
		       ", 'sig=' + t.dataset.sig); }; }"),
    wse:cast(Ws, Sig, "call", [null]),
    V = #{box => Box, body => Body, tab_buttons => Btns, event => Ev,
	  paint => Paint, tabs => Tabs, tab => 0, file => File,
	  mode => hide, shown => #{}, fired => [], glow => #{}, last => #{},
	  goal => Goal, res => Res, marks => #{}, sigs_seen => [], k => ?K,
	  states => state_names(hd(Tabs)), trace => none, at => none,
	  bad => #{}, acts => [], look => none, tshow => false},
    goal(Ws, V),
    V.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%% hide | ladder | code from the panel's bar, tab=N from the view's own.
control(_Ws, undefined, _Tag) -> undefined;
control(Ws, V = #{box := Box}, "hide") ->
    wse:setStyle(Ws, Box, "display:none"),
    V#{mode := hide};
control(Ws, V = #{box := Box}, Tag) when Tag =:= "ladder"; Tag =:= "code" ->
    wse:setStyle(Ws, Box, "display:block"),
    render(Ws, V#{mode := list_to_atom(Tag)});
control(Ws, V = #{mode := Mode}, "tab=" ++ I) ->
    V1 = V#{tab := list_to_integer(I)},
    case Mode of
	hide -> V1;
	_    -> render(Ws, V1)
    end;
%% A click on a contact: holds, does not hold, forgotten. Marks survive a
%% change of tab.
control(Ws, V = #{marks := Ms, tab := I}, "ct=" ++ Id) ->
    Key = {I, Id},
    Ms1 = case maps:find(Key, Ms) of
	      error            -> Ms#{Key => {true, contact_of(V, I, Id)}};
	      {ok, {true, X}}  -> Ms#{Key => {false, X}};
	      {ok, {false, _}} -> maps:remove(Key, Ms)
	  end,
    V1 = V#{marks := Ms1},
    goal(Ws, V1),
    paint(Ws, V1);
%% A signal: on / off for one bit, == / != its value now for more.
control(Ws, V = #{marks := Ms, sigs_seen := Seen}, "sig=" ++ N) ->
    Key = {sig, N},
    Ms1 = case maps:find(Key, Ms) of
	      error            -> Ms#{Key => {true, sig_expr(V, N)}};
	      {ok, {true, X}}  -> Ms#{Key => {false, X}};
	      {ok, {false, _}} -> maps:remove(Key, Ms)
	  end,
    V1 = V#{marks := Ms1, sigs_seen := lists:usort([N | Seen])},
    goal(Ws, V1),
    paint(Ws, V1);
%% From the start of the trace: csp back to its initial values, paused, and
%% its clock held -- the trace says how much time passes, not the person. The
%% code view goes back to csp's own values, which the replay is checking.
control(Ws, V = #{trace := {_, _}}, "replay") ->
    paint(Ws, V#{at := 0, bad := #{}, look := none,
		 acts := [pause, reset, {clock, 0}]});
%% Walk the trace's cycles in the code view, csp left as it is.
control(Ws, V = #{trace := {Rows, _}, look := L}, Dir)
  when Dir =:= "up"; Dir =:= "down" ->
    Last = length(Rows) - 2,
    L1 = case {L, Dir} of
	     {none, _}    -> 0;
	     {_, "up"}    -> max(0, L - 1);
	     {_, "down"}  -> min(Last, L + 1)
	 end,
    paint(Ws, V#{look := L1});
control(Ws, V, "live") ->
    paint(Ws, V#{look := none});
control(Ws, V = #{tshow := T}, "table") ->
    paint(Ws, V#{tshow := not T});
%% One step of the trace: its inputs and the time before it, then the step.
%% A frame goes out a step AHEAD: csp takes it in during one cycle and the
%% rules see .rx in the next.
control(Ws, V = #{trace := {Rows, M}, at := T}, "rstep")
  when is_integer(T), T + 1 < length(Rows) ->
    Row = lists:nth(T + 2, Rows),
    Fs = maps:get(frames, M),
    Sets = [{set, N, X} || N <- maps:get(inputs, M),
			   X0 <- [proplists:get_value(N, Row, '-')],
			   is_integer(X0), X <- [signed(N, X0, M)]] ++
	[{set, lists:flatten([B, "[", integer_to_list(K), "]"]), X}
	 || {B, _, Size} <- Fs, K <- lists:seq(0, Size - 1),
	    X <- [proplists:get_value(byte_col(B, K), Row)], is_integer(X)],
    Out = case T + 3 =< length(Rows) of
	      true ->
		  Ahead = lists:nth(T + 3, Rows),
		  [{frame, Id, [case proplists:get_value(byte_col(B, K), Ahead) of
				    X when is_integer(X) -> X;
				    _ -> 0
				end || K <- lists:seq(0, Size - 1)]}
		   || {B, Id, Size} <- Fs,
		      proplists:get_value(B ++ "_rx", Ahead) =:= 1];
	      false -> []
	  end,
    Dt = case proplists:get_value("u_dt", Row) of
	     D when is_integer(D) -> [{clock, D}];
	     _ -> []
	 end,
    paint(Ws, V#{at := T + 1, look := none,
		 acts := Sets ++ Out ++ Dt ++ [step]});
%% Drop the marks and look at the model itself.
control(Ws, V, "clear") ->
    V1 = V#{marks := #{}},
    goal(Ws, V1),
    ask(Ws, V1, check),
    paint(Ws, V1);
control(Ws, V = #{marks := Ms}, "solve") ->
    case maps:size(Ms) of
	0 -> answer(Ws, V, "", "click a contact or a signal to say what "
		    "should hold");
	_ -> ask(Ws, V, {solve, goal_text(Ms), maps:get(k, V)})
    end,
    V;
control(_Ws, V, "k=" ++ K) ->
    V#{k := list_to_integer(K)};
control(_Ws, V, _Tag) -> V.

%%% ------------------------------------------------------------ the model
%%%
%%% varp runs for a second or more, so it runs beside the panel: the answer
%%% comes back as {csp_model, Answer} and the panel hands it to model/3.

ask(Ws, #{file := File} = V, Q) ->
    answer(Ws, V, "", "asking varp ..."),
    Self = self(),
    spawn(fun() -> Self ! {csp_model, run(File, Q)} end),
    ok.

run(File, Q) ->
    Opts = case Q of
	       check            -> [{params, fixed}];
	       {solve, G, _}    -> [{reach, G}, {params, fixed}]
	   end,
    case {candyspeak_varp:model(File, Opts), varp_sh()} of
	{_, none} ->
	    {error, "varp not found: set VARP_SH to its varp.sh"};
	{{ok, M = #{text := Text, name := Name}}, Sh} ->
	    T = " --timeout " ++ integer_to_list(?VARP_TIMEOUT) ++ " bmc ",
	    case Q of
		check ->
		    {check, M, candyspeak_varp:bmc(
				 Text, T ++ "--runs --k-min 2 --k-max 2 "
				 "--trace false", Sh)};
		{solve, Goal, K} ->
		    {solve, Goal, K, M,
		     candyspeak_varp:prove(M, "--property " ++ Name ++ "_reach",
					   K, ?VARP_TIMEOUT, Sh)}
	    end;
	{Error, _} ->
	    {error, why(Error)}
    end.

varp_sh() ->
    F = case os:getenv("VARP_SH") of
	    false -> filename:join(os:getenv("HOME"), "erlang/varp/priv/varp.sh");
	    Sh    -> Sh
	end,
    case filelib:is_regular(F) of
	true  -> F;
	false -> none
    end.

why({error, {instances_not_modelled, Ms}}) ->
    "no #module for " ++ string:join(Ms, ", ");
why({error, {varp_annotate, Loc, _Kind, {not_modelled, _T, Names}}}) ->
    Loc ++ ": the model has nothing for " ++ string:join(Names, ", ");
why({error, {varp_annotate, Loc, _Kind, Why}}) ->
    lists:flatten(io_lib:format("~s: ~p", [Loc, Why]));
why(Error) ->
    lists:flatten(io_lib:format("~p", [Error])).

model(_Ws, undefined, _A) -> undefined;
model(Ws, V0, {error, Why}) ->
    V = V0#{trace := none, at := none},
    answer(Ws, V, "bad", Why), V;
model(Ws, V, {check, M, {found, _, _}}) ->
    answer(Ws, V, "ok", "the model runs." ++ free_text(M)), V;
model(Ws, V, {check, _M, {none, _}}) ->
    answer(Ws, V, "bad", no_transitions()), V;
model(Ws, V, {solve, Goal, _K, M, {found, At, Rows}}) ->
    answer(Ws, V, "ok",
	   lists:flatten([io_lib:format("reached at step ~w: ~s", [At, Goal]),
			  frames(Rows, M)]),
	   ["\n", buttons(V, ["up", "down", "live", "table", "replay", "rstep"]),
	    " <span id='tr_ev'></span>",
	    "<div id='tr_tab'>", table(Rows, M, V), "</div>"]),
    paint(Ws, V#{trace := {Rows, M}, at := none, bad := #{}, shown := #{},
		 look := 0});
%% No trace, and a proof there never is one: by the rules alone with
%% 0-induction, by the history that leads up to it with more.
model(Ws, V0, {solve, Goal, _K, _M, {proved, 0}}) ->
    V = V0#{trace := none, at := none},
    answer(Ws, V, "ok", "never: " ++ Goal ++ " -- no step can lead into it, "
	   "whatever came before (proved by 0-induction)"), V;
model(Ws, V0, {solve, Goal, _K, _M, {proved, N}}) ->
    V = V0#{trace := none, at := none},
    answer(Ws, V, "ok",
	   lists:flatten(io_lib:format("never: ~s -- no run reaches it "
				       "(proved by ~w-induction)", [Goal, N]))), V;
model(Ws, V0, {solve, Goal, K, _M, {none, _}}) ->
    V = V0#{trace := none, at := none},
    answer(Ws, V, "bad",
	   lists:flatten(io_lib:format("not reachable within ~w steps, and "
				       "not proved for ever: ~s", [K, Goal]))), V;
model(Ws, V0, {solve, _Goal, _K, _M, no_transitions}) ->
    V = V0#{trace := none, at := none},
    answer(Ws, V, "bad", no_transitions()), V;
model(Ws, V, {_, _, {error, Out}}) ->
    answer(Ws, V, "bad", "varp: " ++ Out), V;
model(Ws, V, {_, _, _, _, {error, Out}}) ->
    answer(Ws, V, "bad", "varp: " ++ Out), V.

no_transitions() ->
    "the model has NO transitions: every goal would come back unreachable, "
	"which would mean nothing".

%% What the model does not pin down: worth knowing before believing it.
free_text(#{inputs := In, free := Free, frozen := Fz, abstract := Abs,
	    skipped := Sk}) ->
    lists:flatten(
      [[["\ninput, any value each step: ", string:join(In, ", ")] || In =/= []],
       [["\nwritten by rules it cannot model, so free: ",
	 string:join(Free, ", ")] || Free =/= []],
       [["\n#param, any value but frozen: ", string:join(Fz, ", ")]
	|| Fz =/= []],
       [["\nguards it cannot read (a call, a part), so a free choice: line ",
	 string:join(lists:usort([integer_to_list(Ln) || {_, Ln} <- Abs]),
		     ", ")] || Abs =/= []],
       [io_lib:format("\n~w rules not modelled", [Sk]) || Sk > 0],
       "\n#params are taken at their declared values"]).

byte_col(B, K) -> B ++ "_b" ++ integer_to_list(K).

%% The frames a replay cannot send: on a buffer without a fixed CAN id.
frames(Rows, #{frames := Fs}) ->
    Can = [B || {B, _, _} <- Fs],
    case [{B, I} || {I, R} <- lists:zip(lists:seq(0, length(Rows) - 1), Rows),
		    {C, 1} <- R, lists:suffix("_rx", C),
		    B <- [lists:sublist(C, length(C) - 3)],
		    I > 1, not lists:member(B, Can)] of
	[] -> "";
	Ns ->
	    io_lib:format("\nit receives a frame at step ~s on a buffer with "
			  "no fixed CAN id -- the replay cannot send it, so csp "
			  "will part from it there",
			  [string:join([[B, " ", integer_to_list(I)]
					|| {B, I} <- Ns], ", ")])
    end.

%% What the panel is to send to csp for the view, oldest first.
actions(undefined) -> {[], undefined};
actions(V = #{acts := As}) -> {As, V#{acts := []}}.

buttons(#{event := Ev}, Tags) ->
    [["<button onclick=\"Wse.notify(", integer_to_list(Ev), ",'", T, "')\">",
      case T of
	  "rstep" -> "step";
	  "up"    -> "&#9650;";
	  "down"  -> "&#9660;";
	  _       -> T
      end, "</button>"] || T <- Tags].

%%% ------------------------------------------------------- walking the trace
%%%
%%% `look' is a cycle of the trace, from step L to L+1, shown in the code view
%%% as if csp were in it: the state of step L, the inputs and the time that
%%% come in for the next one -- a cycle reads them as they arrive -- and what
%%% the model's timers say. A rule whose guard holds there is the rule that
%%% fires in that cycle.

look_values(#{trace := {Rows, M}, look := L}) ->
    A = lists:nth(L + 1, Rows),
    B = lists:nth(L + 2, Rows),
    In = maps:get(inputs, M),
    Ints = fun(R, Pred) ->
		   [{C, signed(C, X, M)} || {C, X} <- R, is_integer(X), Pred(C)]
	   end,
    State = Ints(A, fun(C) -> not lists:member(C, In) andalso
				  not lists:prefix("u_", C) end),
    Inputs = Ints(B, fun(C) -> lists:member(C, In) end),
    Dt = proplists:get_value("u_dt", B),
    Timers = lists:append(
	       [timer_values(T, P, proplists:get_value("u_run_" ++ T, A),
			     proplists:get_value("u_el_" ++ T, A), Dt)
		|| {T, P} <- maps:get(timers, M)]),
    Rx = [{{part, Buf, "rx"}, X} || {Buf, _, _} <- maps:get(frames, M),
				   X <- [proplists:get_value(Buf ++ "_rx", B)],
				   is_integer(X)],
    maps:from_list([{"State", X} || {"St", X} <- State] ++
		       [{C, X} || {C, X} <- State, C =/= "St"] ++
		       Inputs ++ Timers ++ Rx).

timer_values(T, P, Run, El, Dt) when is_integer(Run), is_integer(El),
				     is_integer(Dt) ->
    Fire = (Run =:= 1) andalso (El + Dt >= P),
    [{{timeout, T}, b2i(Fire)}, {{elapsed, T}, min(El + Dt, P)},
     {{part, T, "fired"}, b2i(Fire)}, {{part, T, "period"}, P},
     {T, b2i(Run =:= 1 andalso not Fire)}];
timer_values(T, P, _, _, _) -> [{{part, T, "period"}, P}].

b2i(true)  -> 1;
b2i(false) -> 0.

%% The cycle as one line: what comes in, and what it changes.
look_text(#{trace := {Rows, M}, look := L, states := Names})
  when is_integer(L) ->
    A = lists:nth(L + 1, Rows),
    B = lists:nth(L + 2, Rows),
    In = maps:get(inputs, M),
    Show = fun("St", X) ->
		   case lists:keyfind(X, 2, maps:get(states, M)) of
		       {N, _} -> N;
		       false  -> state_name(#{states => Names}, X)
		   end;
	      (C, X) -> integer_to_list(signed(C, X, M))
	   end,
    Got = [[C, "=", Show(C, X)] || {C, X} <- B, lists:member(C, In),
				   is_integer(X), proplists:get_value(C, A) =/= X]
	++ [[Buf, " frame"] || {Buf, _, _} <- maps:get(frames, M),
			      proplists:get_value(Buf ++ "_rx", B) =:= 1],
    Ms = case proplists:get_value("u_dt", B) of
	     D when is_integer(D) -> ["+", integer_to_list(D), " ms"];
	     _ -> []
	 end,
    Changed = [[col_name(C), "=", Show(C, X)]
	       || {C, X} <- B, is_integer(X), not lists:member(C, In),
		  not lists:prefix("u_", C), proplists:get_value(C, A) =/= X],
    lists:flatten(
      io_lib:format("step ~w -> ~w:  ~s~s  =>  ~s",
		    [L, L + 1, Ms, [["  ", G] || G <- Got],
		     case Changed of
			 [] -> "nothing changes";
			 _  -> lists:join(", ", Changed)
		     end]));
look_text(#{trace := {_, _}}) -> "live: csp's own values";
look_text(_) -> "".

%% A signal as a condition: on, or equal to what it is now.
sig_expr(#{tabs := [#{env := Env} | _], last := Last}, N) ->
    F = {field, 0, {'WORD', 0, N}},
    case maps:find(N, maps:get(sigs, Env)) of
	{ok, {1, _}} -> F;
	_ ->
	    X = case candyspeak_eval:eval(F, Last, Env) of
		    I when is_integer(I) -> I;
		    unknown -> maps:get(N, Last, 0)
		end,
	    Lit = case X < 0 of
		      true  -> {'-', 0, {'INT', 0, integer_to_list(-X)}};
		      false -> {'INT', 0, integer_to_list(X)}
		  end,
	    {'==', 0, F, Lit}
    end.

answer(Ws, V, Cls, Text) -> answer(Ws, V, Cls, Text, "").

answer(Ws, #{res := R}, Cls, Text, Table) ->
    wse:set(Ws, R, "className", "md res " ++ Cls),
    wse:set(Ws, R, "innerHTML", lists:flatten([esc(Text), Table])).

%% The trace, a column per step. The abstracted guards become `L26?', the
%% choice of whether that rule may fire; St is shown by name.
table(Rows, M = #{states := Sts}, #{states := Names}) ->
    Cols = cols(Rows),
    Steps = lists:seq(0, length(Rows) - 1),
    Id = fun(C, I) -> [" id='", tr_id(C, I), "'"] end,
    ["<table><tr><th></th>",
     [["<th", Id(step, I), ">", integer_to_list(I), "</th>"] || I <- Steps],
     "</tr>",
     [["<tr><th>", esc(col_name(C)), "</th>",
       [cell(C, signed(C, proplists:get_value(C, R), M), Sts, Names, Id(C, I))
	|| {I, R} <- lists:zip(Steps, Rows)],
       "</tr>"] || C <- Cols],
     "</table>"].

cols(Rows) -> [N || {N, _} <- hd(Rows), N =/= "input"].

tr_id(step, I) -> "tr_" ++ integer_to_list(I);
tr_id(C, I)    -> "tr_" ++ C ++ "_" ++ integer_to_list(I).

%% The state values csp disagrees with at the replay's step, kept per step so
%% a step that went wrong stays red after the next. Not at step 0, where csp
%% has been reset but has dumped nothing yet.
judge(V = #{trace := {Rows, M}, at := At, bad := Bad}, Last)
  when is_integer(At), At > 0 ->
    R = lists:nth(At + 1, Rows),
    V#{bad := Bad#{At => [C || C <- cols(Rows), is_state_col(C, M),
			       not agrees(C, proplists:get_value(C, R), Last, M)]}};
judge(V, _Last) -> V.

%% The replay's classes: the step's column lit, what csp disagreed with red.
trace_classes(#{trace := none}) -> [];
trace_classes(#{trace := {Rows, _M}, at := At, bad := Bad}) ->
    Steps = lists:seq(0, length(Rows) - 1),
    [{tr_id(step, I), case I of At -> "cur"; _ -> "" end} || I <- Steps] ++
	[{tr_id(C, I),
	  string:join([X || X <- [cell_class(proplists:get_value(C, R)),
				  case I of At -> "cur"; _ -> "" end,
				  case lists:member(C, maps:get(I, Bad, [])) of
				      true  -> "bad";
				      false -> ""
				  end], X =/= ""], " ")}
	 || {I, R} <- lists:zip(Steps, Rows), C <- cols(Rows)].

cell_class('-') -> "any";
cell_class(_)   -> "".

is_state_col("St", _M) -> true;
is_state_col("u_free" ++ _, _M) -> false;
is_state_col(C, #{inputs := In, types := Ts}) ->
    maps:is_key(C, Ts) andalso not lists:member(C, In).

%% Compared as stored bits, which is what both sides print.
agrees(_C, '-', _Last, _M) -> true;
agrees("St", X, Last, _M) -> maps:get("State", Last, undefined) =:= X;
agrees(C, X, Last, #{types := Ts}) ->
    {W, _} = maps:get(C, Ts),
    Mask = (1 bsl W) - 1,
    case maps:find(C, Last) of
	{ok, Y} when is_integer(Y) -> (X band Mask) =:= (Y band Mask);
	_ -> false
    end.

%% varp prints the bits; a signed declaration reads them as the runtime does.
signed(C, V, #{types := Ts}) when is_integer(V) ->
    case maps:find(C, Ts) of
	{ok, {W, true}} when V >= 1 bsl (W - 1) -> V - (1 bsl W);
	_ -> V
    end;
signed(_C, V, _M) -> V.

col_name("St") -> "State";
col_name("u_dt") -> "ms";
col_name("u_run_" ++ T) -> T;
col_name("u_el_" ++ T) -> T ++ " ms";
col_name("u_free" ++ T) ->
    case string:split(T, "_L") of
	[_, Ln] -> "L" ++ Ln ++ "?";
	_       -> "u_free" ++ T
    end;
col_name(C) -> C.

cell(_C, '-', _Sts, _Names, Id) -> ["<td class='any'", Id, ">-</td>"];
cell("St", V, Sts, Names, Id) ->
    ["<td", Id, ">", case lists:keyfind(V, 2, Sts) of
			 {N, V} -> N;
			 false  -> maps:get(V, Names, integer_to_list(V))
		     end, "</td>"];
cell(_C, V, _Sts, _Names, Id) when is_integer(V) ->
    ["<td", Id, ">", integer_to_list(V), "</td>"];
cell(_C, V, _Sts, _Names, Id) ->
    ["<td", Id, ">", esc(V), "</td>"].

%%% ------------------------------------------------------------ the marks

%% The contact k<N>_<J> of tab I, with an object's own names made whole.
contact_of(#{tabs := Tabs}, I, Id) ->
    ["k" ++ No, J] = string:split(Id, "_"),
    Tab = lists:nth(I + 1, Tabs),
    [Gd] = [G || #{no := N, guard := G} <- maps:get(rules, Tab),
		 integer_to_list(N) =:= No],
    qualify(lists:nth(list_to_integer(J) + 1, contacts(Gd)), Tab).

qualify(X, #{prefix := none}) -> X;
qualify(X, #{prefix := P, own := Own}) -> qualify(X, P, Own).

qualify({field, L, {'WORD', L2, N}}, P, Own) ->
    case lists:member(N, Own) of
	true  -> {field, L, {'WORD', L2, P ++ "." ++ N}};
	false -> {field, L, {'WORD', L2, N}}
    end;
qualify(T, P, Own) when is_tuple(T) ->
    list_to_tuple([qualify(E, P, Own) || E <- tuple_to_list(T)]);
qualify(L, P, Own) when is_list(L) -> [qualify(E, P, Own) || E <- L];
qualify(X, _P, _Own) -> X.

%% The marks as one condition. Sorted, so the same marks always read the same.
goal_text(Marks) ->
    lists:flatten(
      lists:join(" && ",
		 [case Want of
		      true  -> wrap(candyspeak_eval:text(X));
		      false -> negate(X)
		  end || {_, {Want, X}} <- lists:sort(maps:to_list(Marks))])).

negate({'!', _, Y}) -> wrap(candyspeak_eval:text(Y));
negate(X)           -> ["!", paren(candyspeak_eval:text(X))].

%% A comparison needs no parentheses beside &&, a ! in front of it does.
wrap(T) ->
    case lists:member($|, T) of
	true  -> paren(T);
	false -> T
    end.

paren(T) ->
    case lists:any(fun(C) -> lists:member(C, " |&") end, T) of
	true  -> ["(", T, ")"];
	false -> T
    end.

goal(Ws, #{goal := G, marks := Ms}) ->
    case maps:size(Ms) of
	0 ->
	    wse:set(Ws, G, "className", "goal none"),
	    wse:set(Ws, G, "textContent",
		    "goal: click a contact -- holds, does not, forget");
	_ ->
	    wse:set(Ws, G, "className", "goal"),
	    wse:set(Ws, G, "textContent", "goal: " ++ goal_text(Ms))
    end.

%% The program's state names by number, as the runtime numbers them: the
%% built-ins, then the rest from 3 in order, a repeat or a built-in taking no
%% slot.
state_name(#{states := Names}, N) -> maps:get(N, Names, integer_to_list(N)).

state_names(#{env := #{states := Ss}}) ->
    User = lists:foldl(fun(S, Acc) ->
			       case lists:member(S, ["INIT", "NORMAL", "FAILSAFE"]
						 ++ Acc) of
				   true  -> Acc;
				   false -> Acc ++ [S]
			       end
		       end, [], Ss),
    maps:from_list([{0, "INIT"}, {1, "NORMAL"}, {2, "FAILSAFE"} |
		    lists:zip(lists:seq(3, 2 + length(User)), User)]).

%%% ----------------------------------------------------------------- updates

refresh(_Ws, undefined, _Last) -> undefined;
refresh(Ws, V, Last)           -> paint(Ws, V#{last := Last}).

fired(_Ws, undefined, _Rules) -> undefined;
fired(Ws, V = #{glow := G}, Rules) ->
    Now = erlang:monotonic_time(millisecond),
    G1 = maps:filter(fun(_, T) -> Now - T < ?GLOW end, G),
    paint(Ws, V#{fired := Rules,
		 glow := maps:merge(G1, maps:from_list([{R, Now} || R <- Rules]))}).

%% On the panel's tick: let what has stopped firing go out.
tick(_Ws, undefined) -> undefined;
tick(Ws, V)          -> paint(Ws, V).

render(Ws, V = #{box := Box, body := Body, mode := Mode, tab := I,
		 tab_buttons := Btns}) ->
    Tab = lists:nth(I + 1, maps:get(tabs, V)),
    wse:set(Ws, Box, "className", case Mode of
				      ladder -> "cv";
				      code   -> "cv code"
				  end),
    [wse:set(Ws, B, "className", case J of I -> "sel"; _ -> "" end)
     || {J, B} <- enum(Btns)],
    Html = lists:flatten([head(Tab), html(maps:get(rules, Tab), Mode,
					   V#{env => maps:get(env, Tab),
					      prefix => maps:get(prefix, Tab)})]),
    wse:set(Ws, Body, "innerHTML", Html),
    paint(Ws, V#{shown := #{}}).


%% An object's bindings and its values. The program's own values are in the
%% top frame, where they stay in view.
head(#{binds := none}) ->
    "";
head(Tab = #{binds := {M, Bs}, vars := Vars, prefix := P}) ->
    [["<div class='bind'>#", M, " ", maps:get(name, Tab), " ",
      esc(lists:join("  ", [bind(B) || B <- Bs])), "</div>"],
     vals("v_", P, Vars)].

%% The values with no widget of their own, as a table; a #local in italics.
%% A cell is a signal to mark (data-sig), by its whole name.
vals(_Pre, _Obj, []) -> "";
vals(Pre, Obj, Vars) ->
    ["<div class='vals'>",
     [begin
	  Full = case Obj of none -> N; _ -> Obj ++ "." ++ N end,
	  ["<span data-sig='", Full, "' id='sv_", Full, "'>",
	   case K of local -> ["<i>", N, "</i>"]; var -> N end,
	   "<b id='", Pre, N, "'></b></span>"]
      end || {K, N} <- Vars],
     "</div>"].

%%% ----------------------------------------------------------------- html
%%%
%%% Ids: a rule's coil is k<N>, its contacts k<N>_<I> in walk order, a gate
%%% header g<I>. paint/2 sets classes by id, so the html is written once.

html(Rules, Mode, V) ->
    {Out, _} = lists:mapfoldl(fun(R, G) -> row(R, G, Mode, V) end, 0, Rules),
    Out.

row({gate, 'end', _}, G, _Mode, _V) ->
    {"<div class='hd e'>#end</div>", G};
row({gate, Kind, Arg}, G, _Mode, _V) ->
    T = case Kind of
	    in      -> ["#in ", lists:join(" ", Arg)];
	    'when'  -> ["#when ", candyspeak_eval:text(Arg)]
	end,
    {["<div class='hd' id='g", integer_to_list(G), "'>", esc(T), "</div>"],
     G + 1};
row(R = #{no := N, line := Ln, guard := Gd, assigns := As}, G, Mode, V) ->
    K = "k" ++ integer_to_list(N),
    Label = case {Mode, R} of
		{ladder, #{coil := Tgt}} -> candyspeak_eval:text(Tgt);
		{code, #{coil := Tgt}}   -> [candyspeak_eval:text(Tgt), " ="];
		_ -> lists:join(", ", [assign(A) || A <- As])
	    end,
    Coil = ["<span class='co' id='", K, "'>", esc(Label), "</span>"],
    Ln1 = ["<span class='ln'>", integer_to_list(Ln), "</span>"],
    Body = case {Mode, Gd} of
	       {ladder, undefined} ->
		   [Ln1, "<span class='w' style='width:40px'></span>", Coil];
	       {ladder, _} ->
		   {L, _} = ladder(Gd, K, 0, V),
		   [Ln1, "<span class='w'></span>", L,
		    "<span class='w'></span>", Coil];
	       {code, undefined} ->
		   [Ln1, "<span class='tx'>", Coil, "</span>"];
	       {code, _} ->
		   {T, _} = code(Gd, K, 0, 0, V),
		   Sep = case R of
			     #{coil := _} -> "&nbsp;";
			     _ -> "<span class='op'>&nbsp;?&nbsp;</span>"
			 end,
		   %% one inline run: as flex items the operators would
		   %% lose the spaces around them
		   [Ln1, "<span class='tx'>", Coil, Sep, T, "</span>"]
	   end,
    {["<div class='rw' id='r", integer_to_list(N), "'>", Body, "</div>"], G}.

assign({'=', _, T, X}) -> [candyspeak_eval:text(T), " = ", candyspeak_eval:text(X)];
assign({'<-', _, T, X}) -> [candyspeak_eval:text(T), " <- ", candyspeak_eval:text(X)];
assign({pack, T, _})   -> [candyspeak_eval:text(T), " <<= ..."];
assign({unpack, T, _}) -> [candyspeak_eval:text(T), " >>= ..."];
assign(X)              -> candyspeak_eval:text(X).   % println("ON")

%% As an object line writes it: `Cin=a0.Cout'.
bind({'=', _, T, X}) -> [candyspeak_eval:text(T), "=", candyspeak_eval:text(X)];
bind(B)              -> assign(B).

%% AND horizontal, OR vertical. Returns {Html, NextContact}.
ladder(X = {'&&', _, _, _}, K, I, V) ->
    {Hs, I1} = lists:mapfoldl(fun(C, J) -> ladder(C, K, J, V) end, I,
			      chain('&&', X)),
    {["<span class='and'>", lists:join("<span class='w'></span>", Hs),
      "</span>"], I1};
ladder(X = {'||', _, _, _}, K, I, V) ->
    {Hs, I1} = lists:mapfoldl(fun(C, J) -> ladder(C, K, J, V) end, I,
			      chain('||', X)),
    {["<span class='or'>",
      [["<span class='br'>", H, "<span class='w'></span></span>"] || H <- Hs],
      "</span>"], I1};
ladder(X, K, I, V) ->
    {contact(X, K, I, V), I + 1}.

%% The same walk as text: the contacts in order, the operators between.
code(X = {Op, _, _, _}, K, I, P, V) when Op =:= '&&'; Op =:= '||' ->
    Q = case Op of '||' -> 1; '&&' -> 2 end,
    {Ts, I1} = lists:mapfoldl(fun(C, J) -> code(C, K, J, Q + 1, V) end, I,
			      chain(Op, X)),
    T = lists:join(["<span class='op'> ", atom_to_list(Op), " </span>"], Ts),
    {case Q < P of
	 true  -> ["<span class='op'>(</span>", T, "<span class='op'>)</span>"];
	 false -> T
     end, I1};
code(X, K, I, _P, V) ->
    {contact(X, K, I, V), I + 1}.

chain(Op, {Op, _, L, R}) -> chain(Op, L) ++ chain(Op, R);
chain(_Op, X)            -> [X].

%% A contact. A click marks it, see control/3.
contact(X, K, I, #{event := Ev}) ->
    Id = [K, "_", integer_to_list(I)],
    ["<span class='ct' id='", Id, "' onclick=\"Wse.notify(",
     integer_to_list(Ev), ",'ct=", Id, "')\">",
     esc(candyspeak_eval:text(X)), "</span>"].

esc(T) ->
    lists:flatmap(fun($<) -> "&lt;";
		     ($>) -> "&gt;";
		     ($&) -> "&amp;";
		     (C)  -> [C]
		  end, lists:flatten(T)).

%%% ---------------------------------------------------------------- paint

%% Every id's class from the current state; only what changed is sent, in one
%% cast -- a setStyle per contact would be a round trip each. The top frame's
%% values and State are painted with the view hidden too.
paint(Ws, V = #{last := Last}) ->
    paint1(Ws, judge(V, Last)).

paint1(Ws, V = #{tabs := Tabs, tab := I, last := Live, fired := Now0,
		 glow := Glow, shown := Shown, paint := F, marks := Marks,
		 mode := Mode, look := Look}) ->
    Ms = erlang:monotonic_time(millisecond),
    {Last0, Fired0} =
	case Look of
	    none -> {Live, Now0 ++ [R || {R, T} <- maps:to_list(Glow),
					  Ms - T < ?GLOW]};
	    _    -> {look_values(V), look}
	end,
    #{rules := Rules, env := Env, prefix := P, vars := Vars} =
	lists:nth(I + 1, Tabs),
    Last = values(Last0, P),
    Obj = case P of none -> ""; _ -> P end,
    Fired = case Fired0 of
		look -> look;
		_ -> [{filename:basename(Fl), L} || {O, Fl, L} <- Fired0, O =:= Obj]
	    end,
    State = maps:get("State", Last, 0),
    Mine = maps:from_list([{Id, W} || {{J, Id}, {W, _}} <- maps:to_list(Marks),
				      J =:= I]),
    {Cls, _} = case Mode of
		   hide -> {[], 0};
		   _ -> lists:mapfoldl(
			  fun(R, G) ->
				  classes(R, G, {Env, Last, Mine}, Fired, State)
			  end, 0, Rules)
	       end,
    #{env := MEnv, vars := MVars} = hd(Tabs),
    Val = fun(N, E, Vs) ->
		  show(candyspeak_eval:eval({field, 0, {'WORD', 0, N}}, Vs, E))
	  end,
    Txt = [{"csp_st", "State " ++ state_name(V, maps:get("State", Last0, 0))}] ++
	[{"m_" ++ N, Val(N, MEnv, Last0)} || {_, N} <- MVars] ++
	[{"v_" ++ N, Val(N, Env, Last)} || P =/= none, Mode =/= hide,
					   {_, N} <- Vars],
    Sigs = [{Pre ++ N, case maps:find({sig, N}, Marks) of
			   {ok, {true, _}}  -> "sgt";
			   {ok, {false, _}} -> "sgf";
			   error            -> ""
		       end} || N <- maps:get(sigs_seen, V), Pre <- ["sl_", "sv_"]],
    Look1 = case V of
		#{trace := {_, _}, tshow := Tbl} ->
		    [{"tr_tab", case Tbl of true -> ""; false -> "hid" end},
		     {{t, "tr_ev"}, look_text(V)}];
		_ -> []
	    end,
    New = maps:from_list(lists:append(Cls) ++ Sigs ++ trace_classes(V) ++
			     Look1 ++ [{{t, Id}, T} || {Id, T} <- Txt]),
    Changed = [{Id, C} || {Id, C} <- maps:to_list(New),
			  maps:get(Id, Shown, undefined) =/= C],
    Cs = lists:append([[Id, C] || {Id, C} <- Changed, is_list(Id)]),
    Ts = lists:append([[Id, T] || {{t, Id}, T} <- Changed]),
    case Cs ++ Ts of
	[] -> ok;
	_  -> wse:cast(Ws, F, "call", [null, wse:array(Cs), wse:array(Ts)])
    end,
    V#{shown := New}.

%% An object's tab reads `a0.A' as `A'; its own names win over the globals.
values(Last, none) -> Last;
values(Last, P) ->
    Pre = P ++ ".",
    Own = fun(K) when is_list(K) -> lists:prefix(Pre, K);
	     ({_, K}) -> lists:prefix(Pre, K);
	     ({part, K, _}) -> lists:prefix(Pre, K)
	  end,
    Cut = fun(K) when is_list(K) -> lists:nthtail(length(Pre), K);
	     ({W, K}) -> {W, lists:nthtail(length(Pre), K)};
	     ({part, K, X}) -> {part, lists:nthtail(length(Pre), K), X}
	  end,
    maps:merge(Last, maps:from_list([{Cut(K), V} || {K, V} <- maps:to_list(Last),
						     Own(K)])).

show(unknown) -> "?";
show(V)       -> integer_to_list(V).

classes({gate, 'end', _}, G, _Ctx, _Fired, _State) ->
    {[], G};
classes({gate, Kind, Arg}, G, {Env, Last, _}, _Fired, State) ->
    On = gate_on({Kind, Arg}, Env, Last, State),
    {[{"g" ++ integer_to_list(G), hd_class(On)}], G + 1};
classes(R = #{no := N, guard := Gd, gates := Gs, line := Ln, file := F},
	G, {Env, Last, Marks}, Fired, State) ->
    K = "k" ++ integer_to_list(N),
    Active = lists:all(fun(Gt) -> gate_on(Gt, Env, Last, State) end, Gs),
    Holds = Active andalso
	((Gd =:= undefined) orelse
	 (candyspeak_eval:truth(Gd, Last, Env) =:= true)),
    On = case R of
	     #{coil := Tgt} -> candyspeak_eval:truth(Tgt, Last, Env) =:= true;
	     _ when Fired =:= look -> Holds;      % the trace's cycle: it fires
	     _              -> lists:member({F, Ln}, Fired)
	 end,
    Coil = string:join(["co"] ++ [ "nx" || Holds] ++ [ "on" || On], " "),
    Cs = case Gd of
	     undefined -> [];
	     _ -> leaves(Gd, K, Env, Last, Marks)
	 end,
    {[{K, Coil}, {"r" ++ integer_to_list(N), case Active of
						   true  -> "rw";
						   false -> "rw off"
					       end} | Cs], G}.

gate_on({in, Names}, Env, Last, State) ->
    lists:any(fun(N) ->
		      candyspeak_eval:eval({field, 0, {'WORD', 0, N}},
					   Last, Env) =:= State
	      end, Names);
gate_on({'when', X}, Env, Last, _State) ->
    candyspeak_eval:truth(X, Last, Env) =:= true.

hd_class(true)  -> "hd t";
hd_class(false) -> "hd".

%% The contacts in the order ladder/4 and code/5 numbered them.
leaves(Gd, K, Env, Last, Marks) ->
    Xs = contacts(Gd),
    [begin
	 Id = K ++ "_" ++ integer_to_list(I),
	 {Id, ct_class(X, Env, Last) ++ case maps:find(Id, Marks) of
					    {ok, true}  -> " mt";
					    {ok, false} -> " mf";
					    error       -> ""
					end}
     end || {I, X} <- lists:zip(lists:seq(0, length(Xs) - 1), Xs)].

contacts(X = {Op, _, _, _}) when Op =:= '&&'; Op =:= '||' ->
    lists:append([contacts(C) || C <- chain(Op, X)]);
contacts(X) -> [X].

ct_class(X, Env, Last) ->
    Base = "ct",
    case candyspeak_eval:truth(X, Last, Env) of
	true    -> Base ++ " t";
	false   -> Base;
	unknown -> Base ++ " u"
    end.
