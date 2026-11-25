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
%%% WATCH. A click on a contact, or on a signal among the devices or the
%%% values, shows what it is now in the top frame.
%%%
%%% THE SOLVER (csp_solve, a pane of its own) says what the program should
%%% do and asks varp; a trace it finds is handed here, trace/2, to walk and
%%% to replay.
%%%
%%% REPLAY. A trace varp found is played back on the running csp: reset, then
%%% per step the trace's inputs are set and one step is run. The column of the
%%% step is lit, and a value csp disagrees with is red -- which is what a trace
%%% through a guard the model could not read (L26?) looks like when the real
%%% timer did not run out. What the view cannot do itself, it leaves in
%%% `acts' for the panel to send to csp (actions/1).
%%%
%%% EDIT. The third way to show the program: caned, the structure editor,
%%% on the same canvas -- its rungs lit by lights/1, which judges them as
%%% paint judges the ladder's. A click, a double click, a drag (xy=, dxy=,
%%% sel=) and a key ({key, K}, caned_wx's) go to it; what it saves goes to the
%%% panel as an act: {edit_save, Text} for a file on disk (access edit), the
%%% rules added and switched for a node ({patch, Lines, Switched}, access
%%% patch) -- as the chat's lines go.
%%%
%%% csp says which rules fired as {Object, File, Line} (--fired): a module's
%%% rule is one piece of code run once per instance, so the object says whose
%%% tab lights it, and file and line say which rung. A rule that fires for one
%%% cycle -- a timeout -- would light for one tick and be missed, so a coil
%%% stays lit for ?GLOW ms after it last fired; tick/2 lets it go out.

-module(csp_code).

-export([new/4, new/5, edit_text/1, print_ops/1, source/2, disabled/2, refresh/2, fired/2, infer/5, tick/1, control/2, trace/2, actions/1]).
-export([look/1]).
-export([assign/1, bind/1, chain/2, cols/1, tr_id/2, col_name/1,
	 signed/3]).                                     % for the renderers
-export([contact_of/3, state_name/2,
	 look_values/1, look_text/1, show/1, items/1]).  % tests
-export([split/1]).
-export([rules/1, rules/2, tabs/1, tabs/2]).
-export([lights/1]).

-define(GLOW, 600).                     % ms a coil stays lit after firing
-define(EDIT_COLS, 200).                % the editor's width, in characters

%% The highlights, settable from candid.config ({colors, [{true, "#3f3"}]}).
%% Any css colour. The fill and the text are mixed from it, so one colour is
%% the whole look of a lit contact.
-define(COLOURS, #{true => "#3f3",          % a contact that holds now
		   fired => "#fb3",         % a coil whose rule fired
		   next => "#fb3",          % outline: the guard holds now
		   block => "#bdf",         % the #in / #when block in force
		   want => "#4af",          % a trace: the cycle replayed
		   unwant => "#f55"}).      % a trace: csp disagrees

colours(Cfg) -> maps:merge(?COLOURS, maps:with(maps:keys(?COLOURS), Cfg)).

%%% ------------------------------------------------------------- the rules

%% [{gate, Kind, Arg} | #{no, line, file, guard, assigns, gates}] in source
%% order. `gates' is every block the rule sits in; a rule in none runs in INIT
%% and NORMAL only, as csp has it. `file' is the basename of the file the rule
%% is written in: candyspeak:parse/2 with `sources' marks where an imported
%% file starts and ends, and Top is the file the walk starts in.
rules(Ast) -> rules(Ast, "").

rules(Ast, Top) -> [I || {_, I} <- tagged(Ast, Top)].

%% The whole program walked in csp's order and numbered as csp numbers it --
%% what /list shows and #disable takes: a module's body where the module is
%% written, an object line's own rules where the object is. Each item comes
%% with the module it is in, `none' outside one.
tagged(Ast, Top) ->
    number(walk(Ast, #{cs => consts(Ast), gs => [], mod => none, depth => 0,
		       ins => local_ins(Ast),
		       file => filename:basename(Top)}), 1).

%% Each module's `#local ... in' names: bound on an object line, they are
%% formulas and not rules.
local_ins(Ast) ->
    {_, Mods} = split(Ast),
    maps:map(fun(_, Body) ->
		     [N || {local, _, {'WORD', _, N}, _, Opts, _} <- Body,
			   proplists:get_value(dir, Opts) =:= in]
	     end, Mods).

%% One tab per object, after `main'. #{name, rules, env, prefix, vars, binds}.
tabs(Ast) -> tabs(Ast, "").

tabs(Ast, Top) ->
    {Main, Mods} = split(Ast),
    All = tagged(Ast, Top),
    GEnv = candyspeak_eval:env(Main),
    [#{name => "main", rules => [I || {none, I} <- All], env => GEnv,
       prefix => none, vars => vars(Main), binds => none}] ++
	[#{name => O, rules => [I || {Mi, I} <- All, Mi =:= M], prefix => O,
	   vars => vars(Body),
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
		(K, V) when is_map(V) -> maps:merge(maps:get(K, G), V);
		(_K, V) -> V                       % float: the program's own
	     end, M).

%% The values a tab lists: variables, and #locals marked as worked out.
vars(Ast) ->
    [{var, N} || {variable, _, {'WORD', _, N}, scalar, _, _, _} <- Ast] ++
	[{local, N} || {local, _, {'WORD', _, N}, _, _, X} <- Ast,
		       X =/= undefined].

walk([{source, _, F} | T], C) ->
    walk(T, C#{file := filename:basename(F)});
walk([{module, _, {'WORD', _, M}} | T], C) ->
    walk(T, C#{mod := M, depth := 0});
walk([{module, _, {'WORD', _, M}, _} | T], C) ->
    walk(T, C#{mod := M, depth := 0});
walk([{in, _, Names} | T], C = #{gs := Gs, mod := M, depth := D}) ->
    G = {in, [N || {'WORD', _, N} <- Names]},
    [{M, {gate, in, element(2, G)}} | walk(T, C#{gs := [G | Gs], depth := D + 1})];
walk([{'when', _, X} | T], C = #{gs := Gs, mod := M, depth := D}) ->
    [{M, {gate, 'when', X}} | walk(T, C#{gs := [{'when', X} | Gs],
					   depth := D + 1})];
%% the #end of a module, not of a block in it
walk([{'end', _} | T], C = #{mod := M, depth := 0}) when M =/= none ->
    walk(T, C#{mod := none});
walk([{'end', _} | T], C = #{gs := Gs, mod := M, depth := D}) ->
    [{M, {gate, 'end', none}} | walk(T, C#{gs := tl_or_nil(Gs),
					    depth := max(0, D - 1)})];
walk([{rule, _, _, _} = R | T], C = #{gs := Gs, file := F, mod := Mo}) ->
    [{Mo, M#{file => F,
	     gates => case Gs of
			  [] -> [{in, ["INIT", "NORMAL"]}];
			  _  -> Gs
		      end}} || M <- rule(R)] ++ walk(T, C);
walk([{timer, Ln, {'WORD', _, N}, P, _} | T],
     C = #{cs := Cs, file := F, mod := Mo}) ->
    case period_rule(P, Cs) of
	true ->
	    Tgt = {field, Ln, {part, Ln, {'WORD', Ln, N}, {'WORD', Ln, "period"}}},
	    [{Mo, #{line => Ln, file => F, guard => undefined, gates => [],
		    assigns => [{'=', Ln, Tgt, P}]}} | walk(T, C)];
	false -> walk(T, C)
    end;
walk([{object, Ln, {'WORD', _, M}, {'WORD', _, O}, Bs} | T],
     C = #{file := F, mod := Mo, ins := Ins, gs := Gs}) ->
    [{Mo, {obj, O, M, Bs, Gs}} | [{Mo, R} || R <- object(Ln, F, O, maps:get(M, Ins, []), Bs)]]
	++ walk(T, C);
walk([_ | T], C) -> walk(T, C);
walk([], _C) -> [].

%% An object line's rules, as csp_parse_object emits them: a `<-' to a member
%% that is not a `#local ... in' is a rule of its own; the values it starts
%% with are one rule and `State = NORMAL' another, both run in its INIT. A
%% binding of a `#local ... in' is a formula: no rule, no number.
object(Ln, F, O, Ins, Bs) ->
    In = fun({field, _, {'WORD', _, N}}) -> lists:member(N, Ins);
	    (_) -> false
	 end,
    R = fun(As) -> #{line => Ln, file => F, guard => undefined, gates => [],
		     assigns => As}
	end,
    Statics = [{'=', L, member(O, Tg), X} || {'=', L, Tg, X} <- Bs, not In(Tg)],
    [R([{'<-', L, member(O, Tg), X}]) || {'<-', L, Tg, X} <- Bs, not In(Tg)] ++
	case Statics of
	    [] -> [];
	    _ -> [R(Statics),
		  R([{'=', Ln, {field, Ln, {'WORD', Ln, O ++ ".State"}},
		      {'WORD', Ln, "NORMAL"}}])]
	end.

%% `N' on O's line is O's own: `O.N'.
member(O, {field, L, {'WORD', L2, N}}) ->
    {field, L, {'WORD', L2, O ++ "." ++ N}};
member(O, {field, L, {part, L2, {'WORD', L3, N}, P}}) ->
    {field, L, {part, L2, {'WORD', L3, O ++ "." ++ N}, P}};
member(_O, X) -> X.

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

number([{M, R = #{}} | T], N) -> [{M, R#{no => N}} | number(T, N + 1)];
number([G | T], N)            -> [G | number(T, N)];
number([], _N)                -> [].

%%% ----------------------------------------------------------------- view

%% Hidden until control/3 says ladder or code. Ast is candyspeak:parse/2 of
%% File with `sources'; Cfg is candid.config's say, today the colours.
%%
%% C is the renderer, {Module, Handle} (csp_code_wse and wse's handle for
%% the browser). Where: #{code => the code view's column, status => the top
%% frame's row of boxes (what was clicked goes there), top => the top frame
%% below it (a trace from the solver and the program's values)} -- the
%% renderer's own, handed on.
new(C, Where, Src, Cfg) -> new(C, Where, Src, Cfg, #{}).

%% Opts: float -- how the program's floats read where it runs, fixpoint
%% (Q16.16, the host csp and most boards, the default) or ieee (an ESP32
%% node's image says so); off -- the rules switched off (#disable), by number.
new(C, Where, {Ast, File}, Cfg, Opts) ->
    Float = maps:get(float, Opts, fixpoint),
    Tabs = tabs(Ast, File),
    Cols = colours(Cfg),
    H = cui(C, new, [Where, Tabs, #{colours => Cols}]),
    V = #{ui => C, h => H, event => maps:get(event, H),
	  colours => Cols, metrics => cui(C, metrics, [H]), ladder => none,
	  redraw => false,
	  tabs => Tabs, tab => 0, file => File, float => Float,
	  prog => candyspeak_eval:prog(Ast, File, [{float, Float}]),
	  mode => hide, shown => #{}, fired => [], glow => #{}, last => #{},
	  off => maps:get(off, Opts, []), open => [],
	  access => maps:get(access, Opts, edit), ed => none, eclip => "",
	  edit_at => maps:get(edit_at, Opts, none),
	  editor => maps:get(editor, Opts, false),
	  states => state_names(hd(Tabs)), trace => none, at => none,
	  bad => #{}, acts => [], look => none, tshow => false},
    V.

%% The renderer's function F on its handle, C = {Module, Handle}: csp_code_wse
%% for the browser.
cui({M, H}, F, A) -> apply(M, F, [H | A]).

%% And on the view's own handles too.
vui(#{ui := C, h := H}, F, A) -> cui(C, F, [H | A]).

%% hide | ladder from the panel's bar, tab=N from the view's own. Where the
%% renderer has the editor (editor => true, the desktop's) the ladder IS the
%% editor, caned; `code' and `edit', kept in settings from before, are the
%% ladder too.
control(undefined, _Tag) -> undefined;
control(V = #{editor := true}, Tag) when Tag =:= "ladder"; Tag =:= "code"; Tag =:= "edit" ->
    vui(V, edit_status, [""]),
    edit_mode(V);
control(V, "edit") -> control(V, "ladder");
control(V, Tag) -> control1(V, Tag).

edit_mode(V) ->
    case edit_open(V) of
	{ok, V0} ->
	    V1 = scoped(V0),
	    vui(V1, shown, [true]),
	    render(V1#{mode := edit, esize => none, eops => none, estatus => none,
		       enode => none});
	{error, M} ->
	    V#{acts := maps:get(acts, V) ++ [{log, "the editor: " ++ lists:flatten(M)}]}
    end.

%% The canvas has the keys or not: the editor's frame says so.
control1(V = #{ed := Ed}, "focus=" ++ On) when Ed =/= none ->
    V1 = V#{ed := Ed#{focused => On =:= "on"}},
    case V1 of
        #{mode := edit} -> edit_draw(V1);
        _ -> V1
    end;
control1(V, "focus=" ++ _) -> V;
%% How many rows a page is, the canvas's view says before a page key.
control1(V = #{ed := Ed}, "page=" ++ N) when Ed =/= none ->
    V#{ed := Ed#{page => list_to_integer(N)}};
control1(V, "page=" ++ _) -> V;
control1(V = #{mode := edit}, Tag = {key, _}) -> edit_control(V, Tag);
control1(V = #{mode := edit}, {keys, Ks}) -> edit_draw(lists:foldl(fun(K, Vi) -> edit_key1(Vi, K) end, V, Ks));
control1(V, {keys, _}) -> V;
control1(V = #{mode := edit}, Tag = "xy=" ++ _) -> edit_control(V, Tag);
control1(V = #{mode := edit}, Tag = "dxy=" ++ _) -> edit_control(V, Tag);
control1(V = #{mode := edit}, Tag = "sel=" ++ _) -> edit_control(V, Tag);
control1(V, {key, _}) -> V;
control1(V, "hide") ->
    vui(V, shown, [false]),
    vui(V, edit_status, [""]),
    V#{mode := hide};
%% `code', the rules as text, is gone: a setting kept from then is ladder.
control1(V, Tag) when Tag =:= "ladder"; Tag =:= "code" ->
    vui(V, shown, [true]),
    vui(V, edit_status, [""]),
    render(V#{mode := ladder});
control1(V = #{mode := Mode}, "tab=" ++ I) ->
    V1 = tab_cursor(scoped(V#{tab := list_to_integer(I), esize => none, enode => none})),
    case Mode of
	hide -> V1;
	_    -> render(V1)
    end;
%% An object's line in the flow: its rules shown in place, or not again.
control1(V = #{open := Open}, "obj=" ++ O) ->
    V1 = V#{open := case lists:member(O, Open) of
			true  -> Open -- [O];
			false -> [O | Open]
		    end},
    case maps:get(mode, V1) of
	hide -> V1;
	_    -> render(V1)
    end;
%% A rule's box: switched off or on again. The panel sends the #disable or
%% #enable and says what is off then (disabled/2); the box changes now.
control1(V = #{off := Off, acts := As}, "dis=" ++ No) ->
    N = list_to_integer(No),
    Dis = not lists:member(N, Off),
    Off1 = case Dis of
	       true  -> lists:usort([N | Off]);
	       false -> Off -- [N]
	   end,
    paint(V#{off := Off1, acts := As ++ [{switch, Dis, N}]});
%% From the start of the trace: csp back to its initial values, paused, and
%% its clock held -- the trace says how much time passes, not the person. The
%% code view goes back to csp's own values, which the replay is checking.
control1(V = #{trace := {_, _}}, "replay") ->
    paint(V#{at := 0, bad := #{}, look := none,
		 acts := [pause, reset, {clock, 0}]});
%% Walk the trace's cycles in the code view, csp left as it is.
control1(V = #{trace := {Rows = [_, _ | _], _}, look := L}, Dir)
  when Dir =:= "up"; Dir =:= "down" ->
    Last = length(Rows) - 2,
    L1 = case {L, Dir} of
	     {none, _}    -> 0;
	     {_, "up"}    -> max(0, L - 1);
	     {_, "down"}  -> min(Last, L + 1)
	 end,
    paint(V#{look := L1});
control1(V, "live") ->
    paint(V#{look := none});
control1(V = #{tshow := T}, "table") ->
    paint(V#{tshow := not T});
%% One step of the trace: its inputs and the time before it, then the step.
%% A frame goes out a step AHEAD: csp takes it in during one cycle and the
%% rules see .rx in the next.
control1(V = #{trace := {Rows, M}, at := T}, "rstep")
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
    paint(V#{at := T + 1, look := none,
		 acts := Sets ++ Out ++ Dt ++ [step]});
%% A click on the picture: what is at X, Y.
control1(V = #{ladder := L}, "xy=" ++ XY) when L =/= none ->
    [X, Y] = [list_to_integer(N) || N <- string:lexemes(XY, ",")],
    case csp_ladder:hit(L, X, Y) of
	none -> V;
	Tag  -> control(V, Tag)
    end;
control1(V, _Tag) -> V.

%%% ------------------------------------------------------------------ edit

%% The editor opened on the file, once; kept while the view is shown.
edit_open(V = #{ed := none, file := File, access := A}) ->
    case caned_ui:open(File, A) of
	{ok, S0} ->
	    %% where it was when the panel was built again from a save
	    S = case maps:get(edit_at, V, none) of
		    none -> S0;
		    Ln -> at_line(S0, Ln)
		end,
	    {ok, V#{ed := S#{embedded => true, focused => false}}};
	{error, {L, M}} -> {error, io_lib:format("~s:~w: ~s", [File, L, M])}
    end;
edit_open(V) -> {ok, V}.

%% The whole program for paper, as ops: the editor's text as written, not
%% saved yet too, or the file's when it is not open -- every line, linear,
%% and nothing of editing on it: no cursor, no selection, no lights.
print_ops(V = #{file := File, access := A, metrics := M0}) ->
    Ed0 = case V of
	      #{ed := E = #{}} -> {ok, E};
	      _ -> caned_ui:open(File, A)
	  end,
    case Ed0 of
	{ok, E0} ->
	    Ed = (caned_ui:set_scope(E0, all))#{ln := 0, sel := none, mode := normal},
	    M = M0#{ch := maps:get(ch, M0) + 6, w => round(maps:get(cw, M0) * ?EDIT_COLS)},
	    {Ops, _} = caned_ops:ops(lists:droplast(caned_ui:all(Ed)), M),
	    [case Op of
		 {text, X, Y, T, C, B} -> {text, X, Y + 3, T, C, B};
		 _ -> Op
	     end || Op <- Ops];
	_ -> []
    end.

%% The editor's screen, the whole document, its status line first, as ops
%% on the canvas; the canvas sized again only when the picture's size moved.
edit_draw(V = #{ed := Ed, metrics := M0, tab := I, tabs := Tabs}) ->
    M = M0#{ch := maps:get(ch, M0) + 6, w => round(maps:get(cw, M0) * ?EDIT_COLS)},
    Raw = case V of
	      #{eraw := {Ed, R}} -> R;                 % the layout, as it was
	      _ -> caned_ui:all(Ed)
	  end,
    Rows = caned_ui:light(Raw, Ed#{lights => lights(V)}),
    %% The status line is the head's, over the canvas (edit_status); the
    %% rest is the picture.
    Rows1 = lists:droplast(Rows),
    Status = status_text(lists:last(Rows)),
    maps:get(estatus, V, none) =:= Status orelse vui(V, edit_status, [Status]),
    {Ops0, Hits} = caned_ops:ops(Rows1, M),
    %% A text op is drawn at its row's top here; caned's rows are 6 px
    %% taller than the font, so it goes down half of that.
    Ops = [case Op of
	       {text, X, Y, T, C, B} -> {text, X, Y + 3, T, C, B};
	       _ -> Op
	   end || Op <- Ops0],
    Size = {round(maps:get(cw, M) * ?EDIT_COLS), round(maps:get(ch, M) * length(Rows1))},
    %% A canvas made again (rungs) is an empty one: the ops go to it even
    %% when they are the ones drawn before -- d1's tab and d2's, one module.
    Fresh = maps:get(esize, V, none) =/= Size,
    Fresh andalso vui(V, rungs, [edit, I, lists:nth(I + 1, Tabs), Size]),
    (Fresh orelse maps:get(eops, V, none) =/= Ops) andalso vui(V, draw, [Ops]),
    %% The cursor moved to another node: that node in sight.
    Node = caned_ops:node_rows(Rows1, maps:get(ch, M)),
    case {Node, maps:get(enode, V, none)} of
        {none, _} -> ok;
        {{Y0, Y1, _}, {Y0, Y1, _}} -> ok;
        {{Y0, Y1, _}, _} -> vui(V, see, [Y0, Y1])
    end,
    V#{eraw => {Ed, Raw}, eops => Ops, ehits => Hits, esize => Size,
       estatus => Status, enode => Node}.

%% The status row as one line of text; the choice Tab put in, in brackets.
status_text(Runs) ->
    lists:flatten([case A of
                       menu_sel -> "[" ++ string:trim(T) ++ "] ";
                       _ -> T
                   end || {A, T} <- Runs]).

edit_control(V = #{ehits := Hs}, "xy=" ++ XY) ->
    [X, Y] = xy(XY),
    case caned_ops:hit(Hs, X, Y) of
	{Ln, P} -> edit_key(V, {click, Ln, P});
	none -> V
    end;
edit_control(V = #{ehits := Hs}, "dxy=" ++ XY) ->
    [X, Y] = xy(XY),
    case caned_ops:hit(Hs, X, Y) of
	{Ln, P} -> edit_key(V, {dclick, Ln, P});
	none -> V
    end;
edit_control(V = #{ehits := Hs}, "sel=" ++ R) ->
    [X0, Y0, X1, Y1] = xy(R),
    case {caned_ops:hit(Hs, X0, Y0), caned_ops:hits_in(Hs, {X0, Y0, X1, Y1})} of
	{{Ln, handle}, _} ->
	    case caned_ops:handle_at(Hs, Y1) of
		none -> V;
		To -> edit_key(V, {move, Ln, To})
	    end;
	{_, {Ln, Ps}} -> edit_key(V, {select, Ln, Ps});
	{_, none} -> V
    end;
edit_control(V, {key, K}) -> edit_key(V, K);
edit_control(V, _) -> V.

xy(S) -> [list_to_integer(N) || N <- string:lexemes(S, ",")].



%% A key to the editor; ^V pastes what it last copied.
edit_key(V, K) -> edit_draw(edit_key1(V, K)).

%% A key to the editor, not drawn: several that came at once (a key held
%% down) are taken and the picture drawn once, after the last.
edit_key1(V = #{ed := Ed, eclip := Clip}, K0) ->
    K = case K0 of paste -> {paste, Clip}; _ -> K0 end,
    case caned_ui:key(K, Ed) of
	{ok, S} -> clip(V, S);
	{save, S} -> edit_save(clip(V, S), S)
    end.

clip(V, S = #{clip := none}) -> V#{ed := S};
clip(V, S = #{clip := C}) -> V#{ed := S#{clip := none}, eclip := C}.

%% What the editor has written and not saved, a file's (access edit):
%% {Text, the line the cursor will be on in it} | none. The panel's save
%% and save as take it (candid's save_edited).
edit_text(#{mode := edit, access := edit, ed := #{doc := D, ln := Ln}}) ->
    case caned_doc:dirty(D) of
        true -> {caned_doc:text(D), caned_doc:saved_line(D, max(1, Ln))};
        false -> none
    end;
edit_text(_) -> none.

%% Saved: a file's text to the panel to write; on a node, what was added and
%% switched since the listing, as lines to send.
edit_save(V = #{access := edit, acts := As}, #{doc := D, ln := Ln}) ->
    V#{acts := As ++ [{edit_save, caned_doc:text(D), caned_doc:saved_line(D, max(1, Ln))}]};
edit_save(V = #{access := patch, acts := As, off := Off}, #{doc := D}) ->
    Nos = caned_doc:numbers(D),
    Lines = [string:trim(caned_doc:line(D, L))
	     || {L, _} <- Nos, caned_doc:added(D, L)],
    Switched = [{caned_doc:off(D, L), N} || {L, N} <- Nos,
					    caned_doc:off(D, L) =/= lists:member(N, Off)],
    V#{acts := As ++ [{patch, Lines, Switched}]}.

%%% ------------------------------------------------------------ a trace
%%%
%%% The solver's (csp_solve): {Label, {At, Rows, Model}} to walk and replay,
%%% Label what it is the trace of; none, the solver closed, lets it go.

trace(undefined, _T) -> undefined;
trace(V0, none) ->
    V = V0#{trace := none, at := none, look := none, bad := #{}},
    answer(V, "", ""),
    paint(V);
trace(V0 = #{acts := As}, {Label, {_At, Rows, M}}) ->
    answer(V0, "ok", Label, {Rows, M, maps:get(states, V0)}),
    V = V0#{acts := As ++ [{log, "solver: " ++ Label ++ frames(Rows, M)}]},
    paint(V#{trace := {Rows, M}, at := none, bad := #{}, shown := #{},
	     look := first_cycle(Rows)}).

%% The walk shows a cycle, step L to L+1: a trace reached at step 0 -- the
%% goal holds at once, over the inputs alone -- has none.
first_cycle([_, _ | _]) -> 0;
first_cycle(_)          -> none.

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

%% The cycle the walk shows, for the panel to show too: none while live, or
%% #{values, step, steps, ms} -- the signals as the code view has them, an
%% input by its own name (a pin's sample B_s is what the person did to B),
%% the step the cycle leads to, of how many, and the time the trace has
%% taken to get there.
look(V = #{trace := {Rows, M}, look := L}) when is_integer(L) ->
    B = lists:nth(L + 2, Rows),
    In = maps:get(inputs, M),
    Vs = maps:filter(fun(K, _) -> is_list(K) end, look_values(V)),
    Pins = maps:from_list(
	     [{lists:sublist(C, length(C) - 2), signed(C, X, M)}
	      || {C, X} <- B, is_integer(X), lists:member(C, In),
		 lists:suffix("_s", C)]),
    Ms = lists:sum([D || R <- lists:sublist(Rows, L + 2),
			 D <- [proplists:get_value("u_dt", R)], is_integer(D)]),
    #{values => maps:merge(Vs, Pins), step => L + 1,
      steps => length(Rows) - 1, ms => Ms};
look(_) -> none.

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

answer(V, Cls, Text) -> answer(V, Cls, Text, none).

answer(V, Cls, Text, Trace) -> vui(V, answer, [Cls, Text, Trace]).

%% Not the model's own bookkeeping for a goal's cycle: the shadows of what
%% it read (u_p_, u_q_, u_m_) and u_seen.
cols(Rows) -> [N || {N, _} <- hd(Rows), N =/= "input", not shadow(N)].

shadow("u_seen") -> true;
shadow("u_" ++ [K, $_ | _]) when K =:= $p; K =:= $q; K =:= $m -> true;
shadow(_) -> false.

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

%%% ------------------------------------------------------------ the marks

%% The contact k<N>_<J> of tab I, with an object's own names made whole.
contact_of(#{tabs := Tabs}, I, Id0) ->
    {Tab, Id} = case string:split(Id0, "/") of
		    [O, Own] -> {tab_of(Tabs, O), Own};
		    [_]      -> {lists:nth(I + 1, Tabs), Id0}
		end,
    ["k" ++ No, J] = string:split(Id, "_"),
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

%% The tab's rungs laid out afresh (csp_ladder), and every class sent again.
render(V = #{mode := edit}) -> paint(V);
render(V = #{mode := Mode, tab := I, tabs := Tabs, metrics := Ms}) ->
    Tab = lists:nth(I + 1, Tabs),
    L = csp_ladder:layout(items(V), Mode, Ms),
    vui(V, rungs, [Mode, I, Tab, csp_ladder:size(L)]),
    paint(V#{shown := #{}, ladder := L, redraw := true}).

%%% ----------------------------------------------------------------- updates

%% The program's text after lines were added to what runs (a patch): laid
%% out again as it is shown, the view's tab and mode kept. Text that does not
%% parse leaves the view as it was.
source(undefined, _Text) -> undefined;
source(V = #{file := File, tab := I, float := Float}, Text) ->
    case try candyspeak:parse_text(Text, File, [sources])
	 catch _:Why -> {error, Why}
	 end of
	{ok, Ast} ->
	    Tabs = tabs(Ast, File),
	    V1 = reedit(V#{tabs := Tabs,
			   tab := case I < length(Tabs) of true -> I; false -> 0 end,
			   prog := candyspeak_eval:prog(Ast, File, [{float, Float}]),
			   states := state_names(hd(Tabs)), ladder := none}, Text),
	    case maps:get(mode, V1) of
		hide -> V1;
		_ -> render(V1)
	    end;
	_ -> V
    end.

%% The editor on the program as it is now -- on a node, what was sent is
%% the node's and no longer added -- the cursor on the line it was on.
reedit(V = #{ed := none}, _Text) -> V;
reedit(V = #{ed := Ed = #{ln := Ln}, file := File, access := A}, Text) ->
    case caned_doc:from_text(Text, File) of
	{ok, D} ->
	    S = (caned_ui:new(D, File, A))#{embedded => true,
					    focused => maps:get(focused, Ed, false)},
	    S1 = case Ln > 0 andalso Ln =< caned_doc:nlines(D) andalso
		     caned_doc:rung(D, Ln) =/= none of
		     true -> caned_ui:key({click, Ln, hd(caned_tree:leaves(
							element(2, caned_doc:rung(D, Ln))))},
					  S);
		     false -> {ok, S}
		 end,
	    {ok, S2} = S1,
	    V#{ed := S2#{msg := maps:get(msg, Ed, "")}};
	_ -> V
    end.

%% In the editor an object's tab shows its module, no more: from its
%% #module to its #end (caned_ui's scope); main the whole file.
scoped(V = #{ed := Ed = #{doc := _}, tabs := Tabs, tab := I}) ->
    V#{ed := caned_ui:set_scope(Ed, case maps:get(binds, lists:nth(I + 1, Tabs)) of
                                        {M, _} -> {module, M};
                                        none -> all
                                    end)};
scoped(V) -> V.

%% In the editor, a tab chosen starts at its top, as the file does: the
%% cursor on its first line (Space goes on to the first rung).
tab_cursor(V = #{ed := Ed = #{doc := _}}) ->
    {ok, Ed1} = caned_ui:key(doc_start, Ed),
    V#{ed := Ed1};
tab_cursor(V) -> V.

%% The editor's cursor put on line Ln's node, or the nearest before it.
at_line(S = #{doc := D}, Ln) ->
    Ls = [L || L <- lists:seq(Ln, 1, -1), caned_doc:rung(D, L) =/= none],
    case Ls of
        [L | _] ->
            {ok, S1} = caned_ui:key({click, L, hd(caned_tree:leaves(
                                                     element(2, caned_doc:rung(D, L))))}, S),
            S1;
        [] -> S
    end.

%% The rules switched off, by number, as the panel's file has them.
disabled(undefined, _Off) -> undefined;
disabled(V, Off) -> paint(V#{off := lists:usort(Off)}).

refresh(undefined, _Last) -> undefined;
refresh(V, Last)           -> paint(V#{last := Last}).

fired(undefined, _Rules) -> undefined;
fired(V = #{glow := G}, Rules) ->
    Now = erlang:monotonic_time(millisecond),
    G1 = maps:filter(fun(_, T) -> Now - T < ?GLOW end, G),
    paint(V#{fired := Rules,
		 glow := maps:merge(G1, maps:from_list([{R, Now} || R <- Rules]))}).

%% A node says nothing of which rules fired: work it out. From cycle Prev's
%% values Din to cycle N's Now, when they are one cycle apart (a step; a node
%% running free dumps every so many), the rules candyspeak_eval:cycle/3 knows
%% fired, by object as csp says it. One it cannot know stays dark.
infer(undefined, _Prev, _N, _Din, _Now) -> undefined;
infer(V = #{prog := P}, Prev, N, Din, Now) when is_integer(Prev), N =:= Prev + 1 ->
    #{fired := F} = candyspeak_eval:cycle(P, Din, candyspeak_eval:sampled(P, Now)),
    fired(V, F);
infer(V, _Prev, _N, _Din, _Now) -> V.

%% On the panel's tick: let what has stopped firing go out.
tick(undefined) -> undefined;
tick(V)          -> paint(V).

assign({'=', _, T, X}) -> [candyspeak_eval:text(T), " = ", candyspeak_eval:text(X)];
assign({'<-', _, T, X}) -> [candyspeak_eval:text(T), " <- ", candyspeak_eval:text(X)];
assign({pack, T, _})   -> [candyspeak_eval:text(T), " <<= ..."];
assign({unpack, T, _}) -> [candyspeak_eval:text(T), " >>= ..."];
assign(X)              -> candyspeak_eval:text(X).   % println("ON")

%% As an object line writes it: `Cin=a0.Cout'.
bind({'=', _, T, X}) -> [candyspeak_eval:text(T), "=", candyspeak_eval:text(X)];
bind(B)              -> assign(B).

chain(Op, {Op, _, L, R}) -> chain(Op, L) ++ chain(Op, R);
chain(_Op, X)            -> [X].
%%% ---------------------------------------------------------------- paint

%% Every id's class from the current state; only what changed is sent, in one
%% cast -- a setStyle per contact would be a round trip each. The top frame's
%% values and State are painted with the view hidden too.
paint(V = #{mode := edit, last := Last}) ->
    V1 = paint1(judge(V, Last)),
    V2 = edit_draw(V1),
    %% the head made again (a tab chosen): what it shows sent to it, all of
    %% it -- what went before went to the head it replaced
    case maps:get(esize, V1, none) =:= maps:get(esize, V2) of
        true -> V2;
        false -> paint1(V2#{shown := #{}})
    end;
paint(V = #{last := Last}) ->
    paint1(judge(V, Last)).

paint1(V = #{tabs := Tabs, tab := I, last := Live, fired := Now0,
		 glow := Glow, shown := Shown,
		 mode := Mode, look := Look, off := Off}) ->
    Ms = erlang:monotonic_time(millisecond),
    {Last0, Fired0} =
	case Look of
	    none -> {Live, Now0 ++ [R || {R, T} <- maps:to_list(Glow),
					  Ms - T < ?GLOW]};
	    _    -> {look_values(V), look}
	end,
    #{env := Env, prefix := P, vars := Vars} = lists:nth(I + 1, Tabs),
    Last = values(Last0, P),
    Obj = case P of none -> ""; _ -> P end,
    Fired = case Fired0 of
		look -> look;
		_ -> [{filename:basename(Fl), L} || {O, Fl, L} <- Fired0, O =:= Obj]
	    end,
    State = maps:get("State", Last, 0),
    %% An object shown in the flow is judged over its own values and what
    %% fired for it.
    Ctx = fun(none) -> {{Env, Last, Off}, Fired, State};
	     (O) ->
		  #{env := OEnv} = tab_of(Tabs, O),
		  OLast = values(Last0, O),
		  OFired = case Fired0 of
			       look -> look;
			       _ -> [{filename:basename(Fl), L}
				     || {O1, Fl, L} <- Fired0, O1 =:= O]
			   end,
		  {{OEnv, OLast, Off}, OFired, maps:get("State", OLast, 0)}
	  end,
    {Cls, _} = case Mode of
		   hide -> {[], 0};
		   edit -> {[], 0};                  % the editor lights its own
		   _ -> lists:mapfoldl(fun(R, G) -> item_classes(R, G, Ctx) end,
				       0, items(V))
	       end,
    #{env := MEnv, vars := MVars} = hd(Tabs),
    Val = fun(N, E, Vs) ->
		  show(candyspeak_eval:eval({field, 0, {'WORD', 0, N}}, Vs, E))
	  end,
    Txt = [{"csp_st", "State " ++ state_name(V, maps:get("State", Last0, 0))}] ++
	[{"m_" ++ N, Val(N, MEnv, Last0)} || {_, N} <- MVars] ++
	[{"v_" ++ N, Val(N, Env, Last)} || P =/= none, Mode =/= hide,
					   {_, N} <- Vars],
    Look1 = case V of
		#{trace := {_, _}, tshow := Tbl} ->
		    [{"tr_tab", case Tbl of true -> ""; false -> "hid" end},
		     {{t, "tr_ev"}, look_text(V)}];
		_ -> []
	    end,
    New = maps:from_list(lists:append(Cls) ++ trace_classes(V) ++
			     Look1 ++ [{{t, Id}, T} || {Id, T} <- Txt]),
    Changed = [{Id, C} || {Id, C} <- maps:to_list(New),
			  maps:get(Id, Shown, undefined) =/= C],
    Cs0 = lists:append([[Id, C] || {Id, C} <- Changed, is_list(Id)]),
    Ts = lists:append([[Id, T] || {{t, Id}, T} <- Changed]),
    {V1, Cs} = draw(V, Cs0),
    case Cs ++ Ts of
	[] -> ok;
	_  -> vui(V, paint, [Cs, Ts])
    end,
    V1#{shown := New}.

%% What lights caned's rungs (caned_ui's `lights'), from the same state paint
%% judges the ladder's by: Fun(Line, What) for a line of the top file, What
%% {contact, Expr} (true | false | unknown), coil (fired | next | both |
%% none) or row (on | off: its blocks in force or not).
%%
%% A line is judged in the scope its rule runs in: the main program's over
%% the program's values; a module's body, written once and run per object,
%% over the object of the tab shown -- its own values (`c0.N' read as `N'),
%% what fired for it, its State. On the main tab a module's body is not lit:
%% it is no one's there.
lights(V = #{tabs := Tabs = [Main | _], tab := I, last := Live, fired := Now0,
             glow := Glow, look := Look, file := File}) ->
    Ms = erlang:monotonic_time(millisecond),
    {Last0, Fired0} =
        case Look of
            none -> {Live, Now0 ++ [R || {R, T} <- maps:to_list(Glow), Ms - T < ?GLOW]};
            _ -> {look_values(V), look}
        end,
    Base = filename:basename(File),
    Scope = fun(#{env := Env, rules := Rules, prefix := P}) ->
                    O = case P of none -> ""; _ -> P end,
                    Last = values(Last0, P),
                    Fired = case Fired0 of
                                look -> look;
                                _ -> [{filename:basename(Fl), L} || {O1, Fl, L} <- Fired0,
                                                                    O1 =:= O]
                            end,
                    C = {Env, Last, Fired, maps:get("State", Last, 0)},
                    [{Ln, {R, C}} || R = #{line := Ln, file := F} <- Rules,
                                     F =:= Base orelse F =:= ""]
            end,
    ByLine = maps:from_list(Scope(Main) ++
                                case I of
                                    0 -> [];
                                    _ -> Scope(lists:nth(I + 1, Tabs))
                                end ++
                                %% a module's rungs shown under an object's line
                                [{{in, P, Ln}, X} || T = #{prefix := P} <- tl(Tabs),
                                                     {Ln, X} <- Scope(T)]),
    Active = fun(#{gates := Gs}, {Env, Last, _, State}) ->
                     lists:all(fun(Gt) -> gate_on(Gt, Env, Last, State) end, Gs)
             end,
    fun(Ln, What) ->
            case maps:find(Ln, ByLine) of
                error -> none;
                {ok, {_, {Env, Last, _, _}}} when element(1, What) =:= contact ->
                    candyspeak_eval:truth(element(2, What), Last, Env);
                {ok, {R, C}} when What =:= row ->
                    case Active(R, C) of true -> on; false -> off end;
                {ok, {R = #{guard := Gd}, C = {Env, Last, Fired, _}}} when What =:= coil ->
                    Holds = Active(R, C) andalso
                        ((Gd =:= undefined) orelse
                         (candyspeak_eval:truth(Gd, Last, Env) =:= true)),
                    On = case R of
                             #{coil := Tgt} -> candyspeak_eval:truth(Tgt, Last, Env) =:= true;
                             _ when Fired =:= look -> Holds;
                             #{file := F, line := L} -> lists:member({F, L}, Fired)
                         end,
                    case {On, Holds} of
                        {true, true} -> both;
                        {true, false} -> fired;
                        {false, true} -> next;
                        {false, false} -> none
                    end;
                {ok, _} -> none
            end
    end.

%% The classes of the rungs' pieces go to the picture, which is drawn again
%% when one of them changed; the rest to the renderer's own pieces.
draw(V = #{ladder := none}, Cs) -> {V, Cs};
draw(V = #{mode := hide}, Cs) -> {V, Cs};
draw(V = #{mode := edit}, Cs) -> {V, Cs};
draw(V = #{ladder := L, redraw := Re, colours := Cols}, Cs) ->
    {L1, Rest, Changed} = csp_ladder:set(L, Cs),
    (Changed orelse Re) andalso vui(V, draw, [csp_ladder:ops(L1, Cols)]),
    {V#{ladder := L1, redraw := false}, Rest}.

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

%% `Name = 7', `A > 3 = 1': what was clicked, and what it is in these values.
show(unknown) -> "?";
show(V) when is_float(V) -> float_to_list(V, [{decimals, 4}, compact]);
show(V)       -> integer_to_list(V).

%% Tab I's rules, an object's line among them as {obj, O, M, Bs, Open, Gs}
%% (Open: none when O has no tab of its own; Gs the blocks the line is in),
%% and an open one's rules after it as {in, O, Depth, Item, Outer}: Outer the
%% blocks round each object line it is in, [{Whose, Gs}], none the tab's
%% own. An object in itself is not opened again.
items(#{tabs := Tabs, tab := I, open := Open}) ->
    items(maps:get(rules, lists:nth(I + 1, Tabs)), Tabs, Open, [], 1, none, []).

items(Rules, Tabs, Open, Seen, D, Whose, Outer) ->
    lists:append([item(R, Tabs, Open, Seen, D, Whose, Outer) || R <- Rules]).

item({obj, O, M, Bs, Gs}, Tabs, Open, Seen, D, Whose, Outer) ->
    case [T || T = #{prefix := P} <- Tabs, P =:= O] of
	[#{rules := Rs}] ->
	    case lists:member(O, Open) andalso not lists:member(O, Seen) of
		true ->
		    Outer1 = Outer ++ [{Whose, Gs}],
		    [{obj, O, M, Bs, true, Gs} |
		     [case X of
			  {in, _, _, _, _} -> X;
			  _ -> {in, O, D, X, Outer1}
		      end || X <- items(Rs, Tabs, Open, [O | Seen], D + 1, O, Outer1)]];
		false -> [{obj, O, M, Bs, false, Gs}]
	    end;
	_ -> [{obj, O, M, Bs, none, Gs}]
    end;
item(R, _Tabs, _Open, _Seen, _D, _Whose, _Outer) -> [R].

tab_of(Tabs, O) ->
    hd([T || T = #{prefix := P} <- Tabs, P =:= O]).

%% The classes of an item, those of an opened object's named `O/Id'. What
%% is in an object whose line is in a block not in force is not either.
item_classes({obj, O, _, _, _, Gs}, G, Ctx) ->
    {[{"ob_" ++ O, row_class(blocks_on(Gs, Ctx(none)))}], G};
item_classes({in, O, _D, X, Outer}, G, Ctx) ->
    On = lists:all(fun({W, Gs}) -> blocks_on(Gs, Ctx(W)) end, Outer),
    {Cs, G1} = item_classes(X, G, fun(_) -> Ctx(O) end),
    {[{O ++ "/" ++ Id, outer(Id, C, On)} || {Id, C} <- Cs], G1};
item_classes(R, G, Ctx) ->
    {C, Fired, State} = Ctx(none),
    classes(R, G, C, Fired, State).

blocks_on(Gs, {{Env, Last, _}, _, State}) ->
    lists:all(fun(Gt) -> gate_on(Gt, Env, Last, State) end, Gs).

row_class(true)  -> "rw";
row_class(false) -> "rw off".

outer(_Id, C, true) -> C;
outer("r" ++ _, C, false) -> C ++ " off";
outer("ob_" ++ _, C, false) -> C ++ " off";
outer("g" ++ _, _C, false) -> "hd";
outer(_Id, C, false) -> C.

classes({gate, 'end', _}, G, _Ctx, _Fired, _State) ->
    {[], G};
classes({gate, Kind, Arg}, G, {Env, Last, _}, _Fired, State) ->
    On = gate_on({Kind, Arg}, Env, Last, State),
    {[{"g" ++ integer_to_list(G), hd_class(On)}], G + 1};
classes(R = #{no := N, guard := Gd, gates := Gs, line := Ln, file := F},
	G, {Env, Last, Off}, Fired, State) ->
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
	     _ -> leaves(Gd, K, Env, Last)
	 end,
    Dis = lists:member(N, Off),
    Row = string:join(["rw"] ++ ["off" || not Active] ++ ["dis" || Dis], " "),
    Box = case Dis of true -> "xoff"; false -> "xon" end,
    {[{K, Coil}, {"r" ++ integer_to_list(N), Row},
      {"x" ++ integer_to_list(N), Box} | Cs], G}.

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
leaves(Gd, K, Env, Last) ->
    Xs = contacts(Gd),
    [begin
	 Id = K ++ "_" ++ integer_to_list(I),
	 {Id, ct_class(X, Env, Last)}
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
