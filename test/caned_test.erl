%%% caned's core without a screen: typing, the tree's edits, and a file
%%% saved with nothing changed but the edited line.
-module(caned_test).

-export([run/0]).

-include_lib("wx/include/wx.hrl").

run() ->
    typing(),
    edits(),
    doc(),
    roundtrip(),
    ui(),
    rules(),
    patch(),
    comments(),
    cards(),
    lights(),
    scope(),
    keys(),
    halt(0).

txt(S) -> {ok, X} = caned_text:expr(S), caned_tree:tree(X).

%% A character at a time: what is there so far, made whole by holes.
typing() ->
    Seq = ["x", "x+", "x+1<y", "x+1<y && x>", "x+1<y && x>15 ||",
	   "x+1<y && x>15 || z==17", "a && (b ||"],
    Got = [{caned_tree:text(T), element(1, T)} || S <- Seq, T <- [txt(S)]],
    expect("typed a character at a time, holes where it is not written yet",
	   Got =:= [{"x", leaf}, {"x + _", leaf}, {"x + 1 < y", leaf},
		    {"x + 1 < y && x > _", 'and'},
		    {"x + 1 < y && x > 15 || _", 'or'},
		    {"x + 1 < y && x > 15 || z == 17", 'or'},
		    {"a && (b || _)", 'and'}], Got),
    {'or', [{'and', [_, _]}, {leaf, _}]} = txt("x+1<y && x>15 || z==17"),
    expect("|| after an AND regroups it: the AND is the first branch", true, ok),
    expect("nothing typed is a hole", txt("") =:= {leaf, {hole, 1}}, txt("")),
    expect("an unfinished string is an error, not a tree",
	   element(1, caned_text:expr("a && \"x")) =:= error, nomatch).

edits() ->
    T = txt("a && b && c && d"),
    T2 = ok(caned_tree:replace(T, {[], 2, 3}, "p || q")),
    T3 = ok(caned_tree:replace(T, {[], 2, 3}, "p && q && r")),
    {T4, H4} = caned_tree:add_or(T, [2]),
    {T5, H5} = caned_tree:add_and(T, [4]),
    Got = {caned_tree:copy(T, {[], 2, 3}), caned_tree:text(T2),
	   caned_tree:text(T3), length(element(2, T3)),
	   caned_tree:text(T4), H4, caned_tree:text(T5), H5,
	   caned_tree:text(caned_tree:delete(T, [3])),
	   caned_tree:text(caned_tree:negate(T, [2])),
	   caned_tree:text(caned_tree:negate(caned_tree:negate(T, [2]), [2])),
	   caned_tree:delete(txt("a"), [])},
    expect("ranges copy and replace, contacts go in series and in parallel",
	   Got =:= {"b && c", "a && (p || q) && d", "a && p && q && r && d", 5,
		    "a && (b || _) && c && d", [2, 2],
		    "a && b && c && d && _", [5],
		    "a && b && d", "a && !b && c && d", "a && b && c && d",
		    {leaf, {hole, 0}}}, Got),
    T6 = ok(caned_tree:set_text(T, [2], "x || y")),
    expect("`x || y' typed into a contact is a branch in its place",
	   caned_tree:text(T6) =:= "a && (x || y) && c && d", caned_tree:text(T6)),
    expect("the contacts' paths, left to right",
	   caned_tree:leaves(T4) =:= [[1], [2, 1], [2, 2], [3], [4]],
	   caned_tree:leaves(T4)).

ok({ok, X}) -> X.

%% A file: only the edited line printed anew, its indentation and comment
%% kept; everything else byte for byte.
doc() ->
    Src = "// lamps\n#variable x\n#variable y\n#variable z\n"
	"#digital R1 out 13\n\n"
	"  R1 = x+1<y && x>15   // the rung\n"
	"y = 2 ? x > 3\n",
    {ok, D} = caned_doc:from_text(Src),
    {none, G} = caned_doc:rung(D, 8),
    {Coil, T} = caned_doc:rung(D, 7),
    {T1, _} = caned_tree:add_or(T, []),
    T2 = ok(caned_tree:set_text(T1, [2], "z==17")),
    D1 = caned_doc:set_rung(D, 7, T2),
    Want = "// lamps\n#variable x\n#variable y\n#variable z\n"
	"#digital R1 out 13\n\n"
	"  // the rung\n"
	"  R1 = x + 1 < y && x > 15 || z == 17\n"
	"y = 2 ? x > 3\n",
    expect("a rung edited: printed anew, its `//' above it; the file otherwise as it was",
	   caned_doc:text(D1) =:= Want andalso
	   candyspeak_eval:text(Coil) =:= "R1" andalso
	   caned_tree:text(G) =:= "x > 3", caned_doc:text(D1)),
    expect("nothing edited is the file byte for byte",
	   caned_doc:text(D) =:= Src, caned_doc:text(D)),
    {ok, D2} = caned_doc:from_text("#variable x\n#digital R out 1\nR = _\n"),
    {_, Th} = caned_doc:rung(D2, 3),
    D3 = caned_doc:set_rung(D2, 3, ok(caned_tree:set_text(Th, [], "x > _"))),
    expect("a half-written program saves with its holes, and loads again",
	   caned_doc:text(D3) =:= "#variable x\n#digital R out 1\nR = x > _\n"
	   andalso element(1, caned_doc:from_text(caned_doc:text(D3))) =:= ok,
	   caned_doc:text(D3)),
    expect("a file that does not parse is refused, with its line",
	   element(1, element(2, caned_doc:from_text("#variable x\nx = = 1\n"))) =:= 2,
	   caned_doc:from_text("#variable x\nx = = 1\n")).

%% Every rule in candyspeak's examples and tests printed by caned and parsed
%% again is the same rule: printing a rung loses nothing.
roundtrip() ->
    Root = os:getenv("CANDYSPEAK", filename:join(os:getenv("HOME"), "work/candyspeak")),
    Files = filelib:wildcard(filename:join(Root, "examples/*.csp")) ++
	filelib:wildcard(filename:join(Root, "tests/unit/*.csp")),
    Bad = lists:append([check_file(F) || F <- Files]),
    N = length(Files),
    expect(lists:flatten(io_lib:format("every rule of ~w files printed and parsed again is "
				       "the same", [N])),
	   N > 50 andalso Bad =:= [], lists:sublist(Bad, 5)),
    {Nd, BadD} = lists:foldl(fun(F, {K, B}) ->
				     {K1, B1} = check_decls(F),
				     {K + K1, B ++ B1}
			     end, {0, []}, Files),
    expect(lists:flatten(io_lib:format("every other statement (~w) printed and parsed again "
				       "is the same", [Nd])),
	   Nd > 1000 andalso BadD =:= [], lists:sublist(BadD, 5)).

%% {how many, [{File, Line, Printed}]} for the statements that are no rule.
check_decls(F) ->
    {ok, Bin} = file:read_file(F),
    case parse(binary_to_list(Bin)) of
	{ok, Ss} ->
	    Ds = [S || S <- Ss, element(1, S) =/= rule],
	    {length(Ds), [{F, caned_doc:line_of(S), P} || S <- Ds,
							 P <- [caned_decl:print(S)],
							 parse(P ++ "\n") =/= {ok, [strip(S)]}
							     andalso
							     strip_ok(parse(P ++ "\n")) =/= [strip(S)]]};
	_ -> {0, []}
    end.

strip_ok({ok, Ss}) -> [strip(S) || S <- Ss];
strip_ok(E) -> E.

parse(T) ->
    case candyspeak_scan:string(T) of
	{ok, Toks, _} -> candyspeak_parse:parse(Toks);
	E -> E
    end.

check_file(F) ->
    case caned_doc:load(F) of
	{ok, D} ->
	    [{F, caned_doc:line_of(R), P}
	     || R = {rule, _, _, _} <- caned_doc:stmts(D),
		caned_doc:rung(D, caned_doc:line_of(R)) =/= none,
		P <- [caned_doc:print_rule(R)],
		not same(R, P)];
	{error, _} -> []            % csp's own deliberate errors, #import paths
    end.

same(R, P) ->
    case caned_doc:from_text(P ++ "\n") of
	{ok, D} -> case caned_doc:stmts(D) of
		       [R1] -> strip(R1) =:= strip(R);
		       _ -> false
		   end;
	_ -> false
    end.

%% Lines out: what is left is the tree.
strip(T) when is_tuple(T) ->
    L = [strip(X) || X <- tuple_to_list(T)],
    case L of
	[A, N | Rest] when is_integer(N) -> list_to_tuple([A, 0 | Rest]);
	_ -> list_to_tuple(L)
    end;
strip(L) when is_list(L) -> [strip(X) || X <- L];
strip(X) -> X.

%% The editor a key at a time, its screen as text.
ui() ->
    {ok, D} = caned_doc:from_text("#variable x\n#variable y\n#variable z\n"
				  "#digital R1 out 13\n#digital R2 out 14\n"
				  "R1 = x+1<y && x>15\nR2 = _\n"),
    S0 = caned_ui:new(D, "t.csp"),
    Keys = fun(Ks, S) -> lists:foldl(fun(K, Si) -> {ok, Sj} = caned_ui:key(K, Si), Sj end,
				     S, Ks) end,
    Rungs = fun(S) -> [R || R <- caned_ui:plain(S, 12, 80),
			    string:find(R, "│") =/= nomatch orelse
				string:find(R, "├") =/= nomatch,
			    string:find(R, "t.csp") =:= nomatch] end,
    S1 = Keys([right, $|] ++ "z==17" ++ [enter], S0),
    expect("| on a contact and z==17 written: a branch under it, the coils in line",
	   Rungs(S1) =:= ["   1 ├─┤ x + 1 < y ├──┬─┤ x > 15 ├──┬──( R1 )─┤",
			  "     │                └─┤ z == 17 ├─┘         │",
			  "   2 ├─┤ ░ ├───────────────────────────( R2 )─┤"], Rungs(S1)),
    S2 = Keys([down, enter] ++ "x>", S1),
    expect("being written, the rung shows a hole where it is not finished",
	   lists:last(Rungs(S2)) =:= "   2 ├─┤ x > ░ ├───────────────────────( R2 )─┤"
	   andalso lists:last(caned_ui:plain(S2, 12, 80)) =:= " write: x>▏",
	   Rungs(S2)),
    S3 = Keys([esc, up, $u], S2),
    expect("Esc leaves it as it was, u takes the branch back",
	   Rungs(S3) =:= ["   1 ├─┤ x + 1 < y ├──┤ x > 15 ├──( R1 )─┤",
			  "   2 ├─┤ ░ ├──────────────────────( R2 )─┤"], Rungs(S3)),
    S4 = Keys([left, $!, $&] ++ "y" ++ [enter], S1),     % from z == 17 to x > 15
    expect("! makes a contact normally closed, & puts one after it",
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, S4), 6)) =:=
	       "R1 = x + 1 < y && (!(x > 15) && y || z == 17)",
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, S4), 6))),
    Text = fun(S) -> caned_doc:text(maps:get(doc, S)) end,
    Base = "#variable x\n#variable y\n#variable z\n"
	"#digital R1 out 13\n#digital R2 out 14\n",
    S5 = Keys([$o] ++ "R2" ++ [enter] ++ "y && z" ++ [enter], S0),
    expect("o: a new rung after this one, its coil asked first, then written",
	   Text(S5) =:= Base ++ "R1 = x+1<y && x>15\nR2 = y && z\nR2 = _\n"
	   andalso maps:get(ln, S5) =:= 7
	   andalso Text(Keys([$u], S5)) =:= caned_doc:text(D), Text(S5)),
    S6 = Keys([$O] ++ "R2" ++ [enter, esc], S0),
    expect("Esc while writing a new rung leaves none behind, the cursor back",
	   Text(S6) =:= caned_doc:text(D) andalso maps:get(ln, S6) =:= 6, Text(S6)),
    S7 = Keys([$o] ++ "3 +" ++ [enter], S0),
    expect("a coil that is no name is refused, and asked again",
	   Text(S7) =:= caned_doc:text(D) andalso
	   element(1, maps:get(mode, S7)) =:= coil, maps:get(msg, S7)),
    S8 = Keys([$D], S0),
    expect("D: the rung out, the cursor on the next; u brings it back",
	   Text(S8) =:= Base ++ "R2 = _\n" andalso maps:get(ln, S8) =:= 6 andalso
	   Text(Keys([$u], S8)) =:= caned_doc:text(D), Text(S8)),
    {ok, De} = caned_doc:from_text("#variable x\n#digital R out 1\n"),
    S9 = Keys([down, $o] ++ "R" ++ [enter] ++ "x" ++ [enter], caned_ui:new(De, "e.csp")),
    expect("a file with no rung yet: o on the last declaration puts the first one after it",
	   Text(S9) =:= "#variable x\n#digital R out 1\nR = x\n", Text(S9)),
    %% A rectangle over x > 15 and the branch under it: the OR is selected.
    Sa = Keys([{select, 6, [[2, 1], [2, 2]]}], S1),
    Sc = Keys([copy], Sa),
    expect("a selection of two branches is their OR, and copies as text",
	   maps:get(clip, Sc) =:= "x > 15 || z == 17" andalso
	   maps:get(sel, Sa) =:= {6, {[2], all}}, {maps:get(sel, Sa), maps:get(clip, Sc)}),
    Sp = Keys([{click, 7, []}, {paste, "x > 15 || z == 17"}], Sc),
    expect("pasted onto R2's hole: the OR there",
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sp), 7)) =:=
	       "R2 = x > 15 || z == 17", Text(Sp)),
    Sx = Keys([{select, 6, [[1], [2, 1]]}, cut], S1),
    expect("cut: the selection gone, on the clipboard; a bad paste says so",
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sx), 6)) =:= "R1 = _"
	   andalso maps:get(clip, Sx) =:= "x + 1 < y && (x > 15 || z == 17)"
	   andalso string:prefix(maps:get(msg, Keys([{paste, "a &&& b"}], Sx)),
				 "not pasted") =/= nomatch,
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sx), 6))),
    {_, Rows} = caned_ui:screen(S1, 12, 80),
    {_, Hits} = caned_ops:ops(Rows, #{cw => 10, ch => 20}),
    %% row 6 of the screen is y 100..119; `x > 15' starts at column 22
    expect("a click finds the contact under it, or the nearest on its row; a rectangle "
           "the ones it touches",
	   caned_ops:hit(Hits, 255, 110) =:= {6, [2, 1]} andalso
	   caned_ops:hit(Hits, 55, 110) =:= {6, [1]} andalso      % off a box: the nearest
	   caned_ops:hit(Hits, 55, 5000) =:= none andalso
	   caned_ops:hits_in(Hits, {250, 105, 260, 135}) =:= {6, [[2, 1], [2, 2]]},
	   [H || H = {_, _, _, _, 6, _} <- Hits]),
    Ss = Keys([left, left, shift_right], S1),
    Ss2 = Keys([left, shift_right], S1),               % x > 15 to z == 17
    expect("shift + arrow selects from where it began; into a branch takes the OR",
	   maps:get(sel, Ss) =:= {6, {[], all}} andalso
	   maps:get(sel, Ss2) =:= {6, {[2], all}} andalso
	   maps:get(sel, Keys([right], Ss)) =:= none,
	   {maps:get(sel, Ss), maps:get(sel, Ss2)}),
    %% A rule with no condition: a wire to its coil, written into a guard.
    {ok, Dn} = caned_doc:from_text("#digital Red out 1\n#digital Yellow out 2\n"
				   "#variable a\nRed = 0, Yellow = 0\nYellow = a > 3\n"),
    Sn = caned_ui:new(Dn, "n.csp"),
    expect("Red = 0, Yellow = 0: a rung, a plain wire to its coil",
	   [R || R <- caned_ui:plain(Sn, 8, 80), string:find(R, "├") =/= nomatch] =:=
	       ["   1 ├────────────( Red = 0, Yellow = 0 )─┤",
		"   2 ├─┤ a > 3 ├──( Yellow )──────────────┤"],
	   caned_ui:plain(Sn, 8, 80)),
    Sg = Keys([enter] ++ "a > 1" ++ [enter], Sn),
    Sand = Keys([$&] ++ "a < 9" ++ [enter], Sn),
    expect("written into, the wire is a guard; & on it is the first contact",
	   Text(Sg) =:= "#digital Red out 1\n#digital Yellow out 2\n#variable a\n"
	   "Red = 0, Yellow = 0 ? a > 1\nYellow = a > 3\n" andalso
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sand), 4)) =:=
	       "Red = 0, Yellow = 0 ? a < 9",
	   {Text(Sg), caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sand), 4))}),
    %% The coil: the last stop right, written anew, selected with the rule.
    Sc1 = Keys([down, right, right, enter] ++ [backspace || _ <- "Yellow"] ++ "Red" ++ [enter], Sn),
    Sc2 = Keys([right, enter] ++ [backspace || _ <- "Red = 0, Yellow = 0"] ++ "Red = a" ++ [enter], Sn),
    expect("the coil written: X's target, a guarded rule's assignments",
	   caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sc1), 5)) =:= "Red = a > 3"
	   andalso caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sc2), 4)) =:= "Red = a",
	   {caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sc1), 5)),
	    caned_doc:print_rule(caned_doc:stmt(maps:get(doc, Sc2), 4))}),
    Sr = Keys([{select, 5, [[], coil]}, copy], Sn),
    Sp2 = Keys([{select, 4, [[], coil]}, {paste, maps:get(clip, Sr)}], Sr),
    Scut = Keys([{select, 5, [[], coil]}, cut], Sn),
    expect("a selection with the coil is the rule: copied, pasted over one, cut",
	   maps:get(clip, Sr) =:= "Yellow = a > 3" andalso
	   Text(Sp2) =:= "#digital Red out 1\n#digital Yellow out 2\n#variable a\n"
	   "Yellow = a > 3\nYellow = a > 3\n" andalso
	   Text(Scut) =:= "#digital Red out 1\n#digital Yellow out 2\n#variable a\n"
	   "Red = 0, Yellow = 0\n", {maps:get(clip, Sr), Text(Sp2), Text(Scut)}),
    expect("Tab and ⇧Tab: the next rung, the last",
	   maps:get(ln, Keys([tab], Sn)) =:= 5 andalso
	   maps:get(ln, Keys([tab, shift_tab], Sn)) =:= 4, nomatch),
    {Sw, _} = caned_ui:screen(Keys([{scroll, 3}], S0), 6, 80),
    {Sw2, _} = caned_ui:screen(Keys([down], Sw), 6, 80),
    expect("the wheel scrolls the view and it stays; the cursor moved, it follows",
	   maps:get(top, Sw) =:= 4 andalso maps:get(top, Sw2) =/= 4 orelse
	   maps:get(top, Sw2) =< 7, {maps:get(top, Sw), maps:get(top, Sw2)}),
    {Sw3, _} = caned_ui:screen(Keys([{scroll, 50}], S0), 6, 80),
    expect("scrolled to the end, the last page fills the screen",
	   maps:get(top, Sw3) =:= 8 - 5 + 1, maps:get(top, Sw3)),   % 8 rows, 5 shown
    expect("q will not leave unsaved work, Q will",
	   element(1, caned_ui:key($q, S4)) =:= ok andalso
	   element(1, caned_ui:key($Q, S4)) =:= quit, nomatch).

%% Rules by csp's numbers: #disable on them, the handle, moving one.
-define(RSRC, "#variable x\n#variable y\n#digital R1 out 13\n#digital R2 out 14\n"
	"// three rules\nR1 = x > 1\nR2 = y > 2\nR1 = y < 9\n").

keys(Ks, S) -> lists:foldl(fun(K, Si) -> {ok, Sj} = caned_ui:key(K, Si), Sj end, S, Ks).

text(S) -> caned_doc:text(maps:get(doc, S)).

rungs(S) -> [R || R <- caned_ui:plain(S, 12, 80), string:find(R, "├") =/= nomatch].

rules() ->
    {ok, D} = caned_doc:from_text(?RSRC ++ "#disable 2\n"),
    S0 = caned_ui:new(D, "r.csp"),
    expect("a rung's number is its rule's, ✕ when #disable has it off",
	   [string:slice(R, 0, 5) || R <- rungs(S0)] =:= ["   1 ", "   2✕", "   3 "] andalso
	   caned_doc:off(D, 7) andalso text(S0) =:= ?RSRC ++ "#disable 2\n",
	   rungs(S0)),
    S1 = keys([$-], S0),
    expect("- switches the rule off: the #disable line at the end says so; u back",
	   text(S1) =:= ?RSRC ++ "#disable 1 2\n" andalso
	   text(keys([$-], keys([down], S0))) =:= ?RSRC andalso
	   text(keys([$u], S1)) =:= text(S0), text(S1)),
    S2 = keys([down, alt_down], S0),
    expect("⌥↓: the rule a line down, its mark with it -- now rule 3",
	   text(S2) =:= "#variable x\n#variable y\n#digital R1 out 13\n#digital R2 out 14\n"
	   "// three rules\nR1 = x > 1\nR1 = y < 9\nR2 = y > 2\n#disable 3\n"
	   andalso maps:get(ln, S2) =:= 8, text(S2)),
    S3 = keys([alt_up, alt_up], S0),
    expect("⌥↑ past a comment: a line at a time",
	   text(S3) =:= "#variable x\n#variable y\n#digital R1 out 13\nR1 = x > 1\n"
	   "#digital R2 out 14\n// three rules\nR2 = y > 2\nR1 = y < 9\n#disable 2\n",
	   text(S3)),
    S4 = keys([{move, 8, 6}], S0),
    expect("{move, From, To}: the handle dragged onto another rung",
	   text(S4) =:= "#variable x\n#variable y\n#digital R1 out 13\n#digital R2 out 14\n"
	   "// three rules\nR1 = y < 9\nR1 = x > 1\nR2 = y > 2\n#disable 3\n", text(S4)),
    S5 = keys([{click, 8, handle}], S0),
    S6 = keys([del], S5),
    expect("the handle selects the whole rule, Del takes it out",
	   maps:get(sel, S5) =:= {8, rule} andalso
	   text(S6) =:= "#variable x\n#variable y\n#digital R1 out 13\n#digital R2 out 14\n"
	   "// three rules\nR1 = x > 1\nR2 = y > 2\n#disable 2\n", text(S6)),
    expect("a double click on the handle switches the rule",
	   text(keys([{dclick, 7, handle}], S0)) =:= ?RSRC, nomatch),
    S7 = keys([{paste, "R2 = x == y"}], S0),
    expect("a whole rule pasted onto a contact goes in after its rule",
	   text(S7) =:= "#variable x\n#variable y\n#digital R1 out 13\n#digital R2 out 14\n"
	   "// three rules\nR1 = x > 1\nR2 = x == y\nR2 = y > 2\nR1 = y < 9\n#disable 3\n"
	   andalso maps:get(ln, S7) =:= 7, text(S7)),
    {_, Rows} = caned_ui:screen(S0, 12, 80),
    {_, Hits} = caned_ops:ops(Rows, #{cw => 10, ch => 20}),
    expect("the number is a handle a click finds; a row finds its rung by them",
	   caned_ops:hit(Hits, 20, 150) =:= {6, handle} andalso
	   caned_ops:handle_at(Hits, 195) =:= 8 andalso
	   caned_ops:hit(Hits, 220, 150) =:= {6, coil}, [H || H = {_, _, _, _, 6, _} <- Hits]).

%% Patch mode: as on a node -- rules added at the end, switched off and on.
patch() ->
    {ok, D} = caned_doc:from_text(?RSRC),
    S0 = caned_ui:new(D, "p.csp", patch),
    S1 = keys([enter], S0),
    expect("patch: a rule that was there is not written into",
	   maps:get(mode, S1) =:= normal andalso
	   string:prefix(maps:get(msg, S1), "patch:") =/= nomatch, maps:get(msg, S1)),
    S2 = keys([$o] ++ "R2" ++ [enter] ++ "x < y" ++ [enter, $&] ++ "y > 0" ++ [enter], S0),
    expect("patch: o puts the new rung last, and it is written into; marked +",
	   text(S2) =:= ?RSRC ++ "R2 = x < y && y > 0\n" andalso
	   lists:last([string:slice(R, 0, 5) || R <- rungs(S2)]) =:= "   4+", text(S2)),
    S3 = keys([$-, alt_up, up, alt_down], S2),
    expect("patch: switched off and on is fine, moved past what was there is not",
	   text(S3) =:= ?RSRC ++ "R2 = x < y && y > 0\n#disable 4\n", text(S3)),
    S4 = keys([{paste, "R1 = x != y"}], S0),
    expect("patch: a rule pasted anywhere goes in at the end",
	   text(S4) =:= ?RSRC ++ "R1 = x != y\n", text(S4)),
    expect("patch: D on a rule that was there is refused, on one added it is not",
	   text(keys([$D], S0)) =:= ?RSRC andalso text(keys([$D], S4)) =:= ?RSRC, nomatch).

%% Comments: `//' lines and `#annotate caned comment', stops of the cursor,
%% written anew broken at 80 columns.
-define(CSRC, "#variable x\n#digital R out 1\n// lamps: the first\n// and the second\n\n"
        "R = x > 1   // trailing\n#annotate caned comment \"made by caned\"\nR = x < 0\n").

comments() ->
    {ok, D} = caned_doc:from_text(?CSRC),
    expect("a comment is its lines of `//', or of #annotate caned comment",
           caned_doc:comments(D) =:= [{3, 4, slash, ["lamps: the first", "and the second"]},
                                      {7, 7, annotate, ["made by caned"]}],
           caned_doc:comments(D)),
    S0 = caned_ui:new(D, "c.csp"),
    P = caned_ui:plain(S0, 12, 90),
    Pad = fun(T) -> "     ║ " ++ T ++ lists:duplicate(77 - length(T), $\s) ++ " ║" end,
    expect("a comment in a box with a double frame, its `//' not shown; a `//' after a "
           "rule after its rung",
           lists:sublist(P, 3, 4) =:= ["     ╔" ++ lists:duplicate(79, $═) ++ "╗",
                                       Pad("lamps: the first"), Pad("and the second"),
                                       "     ╚" ++ lists:duplicate(79, $═) ++ "╝"] andalso
           lists:member(Pad("made by caned"), P) andalso
           lists:member("   1 ├─┤ x > 1 ├──( R )─┤  // trailing", P), P),
    expect("↑ ↓ stop on comments too; the cursor starts on the first rung",
           maps:get(ln, S0) =:= 6 andalso
           [maps:get(ln, keys(K, S0)) || K <- [[up], [down], [down, down]]] =:= [3, 7, 8] andalso
           maps:get(cur, keys([up], S0)) =:= comment, nomatch),
    Long = " -- and a third and a fourth, all of them on the same row of the panel, red and green",
    S1 = keys([up, enter] ++ Long ++ [enter], S0),
    L1 = string:split(text(S1), "\n", all),
    expect("written on at the end past 80 columns, the line is broken at a blank",
           lists:sublist(L1, 3, 3) =:=
               ["// lamps: the first",
                "// and the second -- and a third and a fourth, all of them on the same row of",
                "// the panel, red and green"]
           andalso lists:all(fun(L) -> length(L) =< 80 end, L1), lists:sublist(L1, 3, 3)),
    S2 = keys([down, down, $/] ++ "one" ++ [newline] ++ "two" ++ [enter], S0),
    expect("/ a new comment above, ⇧⏎ a new line in it; u takes it back",
           text(S2) =:= "#variable x\n#digital R out 1\n// lamps: the first\n// and the second\n\n"
           "R = x > 1   // trailing\n#annotate caned comment \"made by caned\"\n// one\n// two\n"
           "R = x < 0\n" andalso maps:get(ln, S2) =:= 8 andalso
           text(keys([$u], S2)) =:= ?CSRC, text(S2)),
    expect("Esc on a new comment leaves none",
           text(keys([$/] ++ "zz" ++ [esc], S0)) =:= ?CSRC, nomatch),
    S3 = keys([down, enter, backspace, backspace, backspace, backspace, backspace] ++ "it" ++ [enter], S0),
    expect("an #annotate comment written anew stays one",
           lists:nth(7, string:split(text(S3), "\n", all)) =:= "#annotate caned comment \"made by it\"",
           text(S3)),
    S4 = keys([up, $D], S0),
    S5 = keys([up, alt_up], S0),
    expect("D takes the comment out; ⌥↑ moves it, the line above hops over",
           text(S4) =:= "#variable x\n#digital R out 1\n\nR = x > 1   // trailing\n"
           "#annotate caned comment \"made by caned\"\nR = x < 0\n" andalso
           text(S5) =:= "#variable x\n// lamps: the first\n// and the second\n#digital R out 1\n\n"
           "R = x > 1   // trailing\n#annotate caned comment \"made by caned\"\nR = x < 0\n"
           andalso maps:get(ln, S5) =:= 2, {text(S4), text(S5)}),
    %% Saved: the file read again, the cursor on its rung, what was added
    %% still so.
    File = filename:join(os:getenv("TMPDIR", "/tmp"), "caned_save_test.csp"),
    {ok, Dp} = caned_doc:from_text(?CSRC, File),
    Sp = keys([$&, $o] ++ "R" ++ [enter] ++ "x == 3" ++ [enter, up, $s],
              caned_ui:new(Dp, File, patch)),
    {ok, Bin} = file:read_file(File),
    expect("patch: saved, the cursor on its rung, an added rule still added",
           binary_to_list(Bin) =:= ?CSRC ++ "R = x == 3\n" andalso
           maps:get(ln, Sp) =:= 8 andalso caned_doc:added(maps:get(doc, Sp), 9),
           {binary_to_list(Bin), maps:get(ln, Sp)}),
    {ok, De} = caned_doc:from_text(?CSRC, File),
    Se = keys([$&] ++ "x < 9" ++ [enter, $s], caned_ui:new(De, File)),
    {ok, Bin2} = file:read_file(File),
    expect("saved, the `//' after a rung printed anew goes above it; the cursor stays on it",
           lists:sublist(string:split(binary_to_list(Bin2), "\n", all), 6, 2) =:=
               ["// trailing", "R = x > 1 && x < 9"] andalso maps:get(ln, Se) =:= 7,
           {Bin2, maps:get(ln, Se)}),
    expect("a line laid out by hand keeps its indentation when broken",
           caned_doc:wrap("  ", "    1. " ++ lists:duplicate(40, $a) ++ " " ++ lists:duplicate(40, $b), 60)
           =:= ["  //     1. " ++ lists:duplicate(40, $a), "  // " ++ lists:duplicate(40, $b)],
           caned_doc:wrap("  ", "    1. " ++ lists:duplicate(40, $a) ++ " " ++ lists:duplicate(40, $b), 60)).

%% Declarations as cards: a field at a time, what it can be offered.
-define(DSRC, "#digital R1 out 13\n#buffer Net:160 inout\n#variable x\nR1 = x > 1\n").

cards() ->
    {ok, D} = caned_doc:from_text(?DSRC),
    S0 = keys([up, up, up], caned_ui:new(D, "d.csp")),
    expect("a declaration is a stop, its fields side by side, the cursor on the name",
           maps:get(ln, S0) =:= 1 andalso maps:get(cur, S0) =:= {seg, 1} andalso
           hd(caned_ui:plain(S0, 8, 80)) =:= "     #digital R1 out 13 +",
           caned_ui:plain(S0, 8, 80)),
    S1 = keys([right, enter, tab], S0),
    expect("on an option, Tab offers the others of its group: out, then inout",
           element(4, maps:get(mode, S1)) =:= "inout" andalso
           string:find(lists:last(caned_ui:plain(S1, 8, 80)), " in  out  inout") =/= nomatch,
           {maps:get(mode, S1), lists:last(caned_ui:plain(S1, 8, 80))}),
    expect("⏎ takes it: the line printed anew",
           hd(string:split(text(keys([enter], S1)), "\n")) =:= "#digital R1 inout 13", nomatch),
    S2 = keys([$+] ++ "pullu" ++ [tab, enter], S0),
    expect("+ puts on an option of a group it has not got, after the others",
           hd(string:split(text(S2), "\n")) =:= "#digital R1 out pullup 13" andalso
           maps:get(cur, S2) =:= {seg, 3}, {text(S2), maps:get(cur, S2)}),
    expect("x takes an option off",
           hd(string:split(text(keys([$x], S2)), "\n")) =:= "#digital R1 out 13", nomatch),
    S3 = keys([down, $+] ++ "tcp 5000" ++ [enter], S0),
    expect("a #buffer's transport put on with +",
           lists:nth(2, string:split(text(S3), "\n", all)) =:= "#buffer Net:160 inout tcp 5000",
           text(S3)),
    S4 = keys([down, right, enter, backspace, backspace, backspace] ++ "x+" ++ [enter], S0),
    expect("a field that does not parse is refused and stays written",
           text(S4) =:= ?DSRC andalso element(1, maps:get(mode, S4)) =:= field
           andalso maps:get(msg, S4) =/= "", {maps:get(mode, S4), maps:get(msg, S4)}),
    expect("a rectangle over a card is a click on its first field, no crash",
           maps:get(cur, keys([{select, 2, [{seg, 2}, {seg, 3}]}], S0)) =:= {seg, 2}, nomatch),
    expect("the name is not written on the card",
           maps:get(mode, keys([enter], S0)) =:= normal, nomatch),
    S5 = keys([$&] ++ "R1." ++ [tab, tab, enter], caned_ui:new(D, "d.csp")),
    expect("`R1.' and Tab in a contact: R1's parts, a Tab each",
           lists:nth(4, string:split(text(S5), "\n", all)) =:= "R1 = x > 1 && R1.pin"
           andalso string:find(lists:last(caned_ui:plain(keys([$&] ++ "R1.", caned_ui:new(D, "d.csp")),
                                                         8, 120)), "Tab: val pin port") =/= nomatch,
           text(S5)).

%% Lit by what holds, as candid lights it: a fun from {line, what} to a light.
lights() ->
    {ok, D} = caned_doc:from_text("#variable x\n#variable y\n#digital R1 out 13\n"
                                  "#digital R2 out 14\nR1 = x > 1 && y > 2\nR2 = x < 0\n"),
    Txt = fun(E) -> candyspeak_eval:text(E) end,
    L = fun(5, {contact, E}) ->
                case Txt(E) of "x > 1" -> true; "y > 2" -> unknown end;
           (5, coil) -> fired; (6, coil) -> next; (6, row) -> off; (_, _) -> none end,
    S = (caned_ui:new(D, "l.csp"))#{lights => L, cur := coil},
    {_, Rows} = caned_ui:screen(S, 10, 80),
    At = maps:from_list([{Where, A} || R <- Rows, {{A, Where}, _} <- R]),
    expect("lit: a contact that holds, one that cannot be known, a fired coil, a rung "
           "whose block is not in force dim",
           maps:get({5, [1]}, At) =:= contact_t andalso maps:get({5, [2]}, At) =:= contact_u
           andalso maps:get({6, []}, At) =:= off andalso maps:get({6, coil}, At) =:= coil_off,
           At),
    {_, Rows2} = caned_ui:screen(S#{cur := [1]}, 10, 80),
    At2 = maps:from_list([{Where, A} || R <- Rows2, {{A, Where}, _} <- R]),
    expect("the cursor outshines a light; a coil not under it shows it fired",
           maps:get({5, [1]}, At2) =:= cur andalso maps:get({5, coil}, At2) =:= coil_on,
           At2),
    {Ops, _} = caned_ops:ops(Rows, #{cw => 10, ch => 20}),
    expect("a lit contact is drawn green", lists:member({51, 255, 51}, [St || {rect, _, _, _, _, _, _, St, _} <- Ops]),
           nomatch).

%% An object's tab: its module alone, from the comment over #module to its
%% #end, and the cursor kept in it.
scope() ->
    {ok, D} = caned_doc:from_text("#variable x\n#digital Top out 1\nTop = x > 1\n"
                                  "// the counter\n#module Cnt\n#local A in\n#local Q out\n"
                                  "Q = A > 2\nQ = A < 0\n#end\n#Cnt c0 A=x\n"),
    S0 = (caned_ui:new(D, "s.csp"))#{scope => {module, "Cnt"}},
    {ok, S} = caned_ui:key({click, 8, [1]}, S0),
    Rows = caned_ui:plain(S, 20, 80),
    Has = fun(T) -> [R || R <- Rows, string:find(R, T) =/= nomatch] =/= [] end,
    Downs = lists:foldl(fun(_, Si) -> {ok, Si1} = caned_ui:key(down, Si), Si1 end, S,
                        lists:seq(1, 5)),
    Ups = lists:foldl(fun(_, Si) -> {ok, Si1} = caned_ui:key(up, Si), Si1 end, S,
                      lists:seq(1, 9)),
    expect("scope: a module alone, its comment and #end in, the rest of the file out, "
           "the cursor kept in it",
           Has("the counter") andalso Has("A > 2") andalso Has("#end")
           andalso not Has("Top") andalso not Has("#Cnt c0")
           andalso maps:get(ln, Downs) =:= 10 andalso maps:get(ln, Ups) =:= 4,
           {Rows, maps:get(ln, Downs), maps:get(ln, Ups)}).

%% Keys by name, a table over them; a page, the ends of a rung and of the
%% file.
keys() ->
    K = fun(Code, U, C, A, Sh) -> caned_keys:name(#wxKey{keyCode = Code, uniChar = U,
                                                           controlDown = C, altDown = A,
                                                           shiftDown = Sh}) end,
    Names = [K(3, 3, true, false, false), K($C, $C, true, false, false),
             K(?WXK_HOME, 0, true, false, false), K(?WXK_PAGEDOWN, 0, false, false, false),
             K(?WXK_TAB, 0, false, false, true), K($<, $|, true, true, false),
             K($a, $a, false, false, false), K(?WXK_UP, 0, false, true, false)],
    T = caned_keys:table([{"C-n", down}, {"C-c", none}]),
    expect("keys named as Emacs does; AltGr the character; the settings over the defaults",
           Names =:= ["C-c", "C-c", "C-home", "pgdn", "S-tab", "|", "a", "M-up"]
           andalso caned_keys:command("C-n", T) =:= down
           andalso caned_keys:command("C-c", T) =:= none
           andalso caned_keys:command("C-v", T) =:= paste
           andalso caned_keys:command("x", T) =:= $x
           andalso caned_keys:command("M-x", T) =:= none, Names),
    E = caned_keys:table([emacs, {"C-z", $u}]),
    Feed = fun(Ns) -> lists:foldl(fun(N, {_, P}) ->
                                          case caned_keys:feed(N, P, E) of
                                              {prefix, P1} -> {{prefix, P1}, P1};
                                              R -> {R, []}
                                          end
                                  end, {none, []}, Ns) end,
    expect("sequences: C-x waits, C-x C-s saves, C-x C-q is undefined; emacs's keys, "
           "one of the settings' over them; a plain key as before",
           element(1, Feed(["C-x"])) =:= {prefix, ["C-x"]}
           andalso element(1, Feed(["C-x", "C-s"])) =:= {command, $s}
           andalso element(1, Feed(["C-x", "C-q"])) =:= {undefined, "C-x C-q"}
           andalso element(1, Feed(["C-v"])) =:= {command, page_down}
           andalso element(1, Feed(["C-z"])) =:= {command, $u}
           andalso element(1, Feed(["a"])) =:= {command, $a}
           andalso element(1, Feed(["home"])) =:= {command, doc_start}
           andalso caned_keys:feed("C-x", [], caned_keys:table([])) =:= {command, cut},
           Feed(["C-x", "C-q"])),
    Src = lists:append(["#variable x\n#digital R out 1\n" |
                        ["R = x > " ++ integer_to_list(I) ++ " && x < 9\n" || I <- lists:seq(1, 30)]]),
    {ok, D} = caned_doc:from_text(Src),
    S = (caned_ui:new(D, "k.csp"))#{page => 10},
    Go = fun(Ks, S0) -> lists:foldl(fun(Ki, Si) -> {ok, Si1} = caned_ui:key(Ki, Si), Si1 end,
                                    S0, Ks) end,
    #{ln := L0} = S,
    #{ln := L1} = Go([page_down], S),
    #{ln := L2} = Go([page_down, page_up], S),
    #{ln := Le} = Go([doc_end], S),
    #{ln := Ls} = Go([doc_end, doc_start], S),
    #{cur := Ce} = Go([rung_end], S),
    #{cur := Cs} = Go([rung_end, rung_start], S),
    expect("page down and up a page of rows; the first and the last stop (a card first); the coil "
           "and the first contact",
           L1 =:= L0 + 10 andalso L2 =:= L0 andalso Le =:= 32 andalso Ls =:= 1
           andalso Ce =:= coil andalso Cs =:= [1],
           {L0, L1, L2, Le, Ls, Ce, Cs}).

expect(What, true, _)  -> io:format("ok    ~ts~n", [What]);
expect(What, false, D) ->
    io:format("FAIL  ~ts: ~tp~n", [What, D]),
    halt(1).
