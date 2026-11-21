%%% caned's editor without a terminal: a state, a key at a time, and the
%%% screen as rows of {Attr, String} runs. caned_tty puts those on a
%%% terminal; the tests read them as text.
%%%
%%% The cursor is on a contact of a rung (a line number and a path in its
%%% tree). Keys:
%%%
%%%   ← →        the contact before, after      ↑ ↓   the rung above, below
%%%   ⇧← ⇧→      select from here on            Tab ⇧Tab  the next, the last rung
%%%
%%% The coil is the last stop to the right (its path `coil'): ⏎ writes it --
%%% the target of `X = <condition>', the assignments of the rest. A selection
%%% that takes the coil is the whole rule: copied as its line, cut as it.
%%%   ⏎ or e     write the contact anew         &     a contact in series
%%%   |          a branch in parallel           !     normally closed / open
%%%   x or Del   the contact out                u     undo, ^R redo
%%%   o O        a new rung after, before       D     the rung out
%%%   -          the rule off (#disable), on    ⌥↑ ⌥↓ the rule a line up, down
%%%   s          save                           q     quit (Q: unsaved too)
%%%
%%% The number left of a rung is its RULE number, csp's -- what #disable
%%% takes -- not its line; ✕ after it: off. It is the rule's handle:
%%% {click, Ln, handle} selects the whole rule (Del then takes it out),
%%% {dclick, Ln, handle} switches it off or on, {move, Ln, To} puts it on
%%% line To.
%%%
%%% A comment (caned_doc) is a stop of the cursor too, as a rung is:
%%%   /          a new comment above            ⏎ or e  write it
%%%   D x Del    the comment out                ⌥↑ ⌥↓   it a line up, down
%%% Writing a comment, the text is shown broken as it will be saved;
%%% ⇧⏎ (^J) starts a new line, ⏎ takes it, Esc leaves it as it was.
%%%
%%% A declaration (any statement that is no rule or comment) is a CARD: its
%%% fields (caned_decl:segs/1) side by side, the cursor on one of them
%%% ({seg, I}):
%%%   ← →        the field before, after        ⏎ or e  write it
%%%   +          an option, a width, a transport onto it
%%%   x Del      an option (a width, ...) off   D       the line out
%%% Writing a field, the status line shows what it can be (caned_menu): Tab
%%% and ↓ put the next choice in, ⇧Tab and ↑ the one before; what is typed
%%% narrows them. ⏎ takes it when the line still parses as the same kind of
%%% declaration. The name is not written here: renaming follows its uses.
%%% Writing a contact, `Name.' and Tab give Name's parts the same way.
%%%
%%% Two ways to work (access): EDIT, on a file -- anything goes -- and PATCH,
%%% as on a node that runs the program: rules are only added, at the end,
%%% and switched off and on; what was there is not changed. A new rung or a
%%% pasted rule goes last, and only what was added can be written in, moved
%%% or taken out. Added rules are marked +.
%%%
%%% From a window (caned_wx) also: {click, Ln, Path} puts the cursor there,
%%% {dclick, Ln, Path} writes it, {select, Ln, Paths} selects the range those
%%% contacts make (caned_tree:range/2); then copy and cut leave its text in
%%% the state's clip for the window's clipboard, and {paste, Text} puts text in
%%% place of the selection, or of the contact under the cursor.
%%%
%%% Writing, the rung shows what is typed so far after every key, holes where
%%% it is not finished (caned_text); ⏎ takes it, Esc leaves it as it was.
%%% A new rung asks for its coil first, then its condition is written: the
%%% two are one change, and Esc on either leaves no rung behind.

-module(caned_ui).

-export([new/2, new/3, open/1, open/2, key/2, screen/3, plain/3, sel_text/1]).

-define(HELP, "←→ contact  ↑↓ rung  ⏎ write  & series  | parallel  "
	"! not  x out  o new  / comment  D out  - off/on  ⌥↑↓ move  u undo  s save  q quit").
-define(PATCH_ONLY, "patch: only rules added at the end, and rules off and on").

open(File) -> open(File, edit).

open(File, Access) ->
    case caned_doc:load(File) of
	{ok, D} -> {ok, new(D, File, Access)};
	E -> E
    end.

new(D, File) -> new(D, File, edit).

%% Access: edit | patch.
new(D, File, Access) ->
    S = #{doc => D, file => File, ln => 0, cur => [], mode => normal, access => Access,
	  undo => [], redo => [], msg => "", top => 1, sel => none, clip => none},
    case rungs(D) ++ stops(D) of                    % on the first rung
	[L | _] -> S#{ln := L, cur := cur_for(D, L)};
	[] -> S
    end.

rungs(D) -> [N || N <- lists:seq(1, caned_doc:nlines(D)), caned_doc:rung(D, N) =/= none].

%% Where the cursor stops: the rungs, the comments by their first line, the
%% declarations.
stops(D) -> lists:usort(rungs(D) ++ [F || {F, _, _, _} <- caned_doc:comments(D)] ++ cards(D)).

%% The lines that are declarations: statements, no rule, no comment.
cards(D) ->
    Cs = lists:append([lists:seq(F, L) || {F, L, _, _} <- caned_doc:comments(D)]),
    [caned_doc:line_of(S) || S <- caned_doc:stmts(D), element(1, S) =/= rule,
			     not lists:member(caned_doc:line_of(S), Cs)].

cur_for(D, L) ->
    case {caned_doc:rung(D, L), caned_doc:stmt(D, L)} of
	{none, none} -> comment;
	{none, {annotate, _, {'WORD', _, "caned"}, {'WORD', _, "comment"}, _}} -> comment;
	{none, _} -> {seg, 1};
	_ -> first_leaf(D, L)
    end.

%% The lines the node on Ln takes: {First, Last}.
span(#{cur := comment}, D, Ln) ->
    {F, L, _, _} = caned_doc:comment_at(D, Ln),
    {F, L};
span(_, _D, Ln) -> {Ln, Ln}.

tree(D, Ln) -> element(2, caned_doc:rung(D, Ln)).

first_leaf(D, Ln) -> hd(caned_tree:leaves(tree(D, Ln))).

%%% ------------------------------------------------------------------ keys

%% {ok, S} | {quit, S}.
key(K, S = #{mode := {edit, Text}}) -> edit(K, Text, S);
key(K, S = #{mode := {edit_coil, Text}}) -> edit_coil(K, Text, S);
key(K, S = #{mode := {coil, Text, At}}) -> coil_key(K, Text, At, S);
key(K, S = #{mode := {note, Text, At, Where}}) -> note(K, Text, At, Where, S);
key(K, S = #{mode := {field, Key, Typed, Text, Sel}}) -> field(K, Key, Typed, Text, Sel, S);
key(newline, S) -> key(enter, S);
key(K, S = #{access := patch}) ->
    case patch_ok(K, S) of
	true -> key1(K, S);
	false -> {ok, S#{msg := ?PATCH_ONLY}}
    end;
key(K, S) -> key1(K, S).

%% The rule's handle: the whole rule selected; switched off or on.
key1({click, Ln, handle}, S) -> key1({rule, Ln}, S);
key1({rule, Ln}, S = #{doc := D}) ->
    {ok, maps:remove(free, S#{ln := Ln, cur := first_leaf(D, Ln), sel := {Ln, rule},
			      msg := "selected: " ++ copy(D, Ln, rule)})};
key1({dclick, Ln, handle}, S = #{doc := D}) ->
    switch(S#{ln := Ln, cur := first_leaf(D, Ln), sel := none});
key1({move, From, To}, S = #{doc := D, ln := Ln, cur := P, undo := Us}) when From =/= To ->
    D1 = caned_doc:move_line(D, From, To),
    Cur = case From of Ln -> P; _ -> first_leaf(D1, To) end,
    {ok, maps:remove(free, S#{doc := D1, undo := [D | Us], redo := [], ln := To, cur := Cur,
			      sel := none})};
key1({move, _, _}, S) -> {ok, S};
%% A line up or down: the line above or below hops over the node.
key1(K, S = #{doc := D, ln := Ln, undo := Us}) when Ln > 0, K =:= alt_up; Ln > 0, K =:= alt_down ->
    {F, L} = span(S, D, Ln),
    {From, To, Ln1} = case K of
			  alt_up -> {F - 1, L, F - 1};
			  alt_down -> {L + 1, F, F + 1}
		      end,
    case From >= 1 andalso From =< caned_doc:nlines(D) of
	true ->
	    {ok, maps:remove(free, S#{doc := caned_doc:move_line(D, From, To), ln := Ln1,
				      undo := [D | Us], redo := [], sel := none, msg := ""})};
	false -> {ok, S}
    end;
%% A new comment: above the cursor's rung or comment, at the end in patch
%% mode or when there is none.
key1($/, S = #{doc := D, ln := Ln, access := A}) ->
    At = case Ln of
	     _ when Ln =:= 0; A =:= patch -> caned_doc:last_line(D);
	     _ -> element(1, span(S, D, Ln))
	 end,
    {ok, S#{mode := {note, "", 0, {new, At}}, msg := "", sel := none}};
key1({dclick, Ln, comment}, S) -> key1(enter, S#{ln := Ln, cur := comment, sel := none});
key1(K, S = #{cur := comment}) -> comment_key(K, S);
key1({dclick, Ln, {seg, I}}, S) -> key1(enter, S#{ln := Ln, cur := {seg, I}, sel := none});
key1({click, Ln, add}, S = #{doc := D}) -> key1($+, S#{ln := Ln, cur := cur_for(D, Ln)});
key1(K, S = #{cur := {seg, _}}) -> card_key(K, S);
%% Del on a selection: what is selected out, the clipboard as it was.
key1(K, S = #{sel := {_, _}, clip := C}) when K =:= del; K =:= $x ->
    {ok, S1} = key1(cut, S),
    {ok, S1#{clip := C}};
key1(K, S) -> key2(K, S).

%% In patch mode: what was there is only switched off and on.
patch_ok(K, S = #{doc := D, ln := Ln}) ->
    Added = fun(L) -> caned_doc:added(D, L) end,
    case K of
	_ when K =:= enter; K =:= $e; K =:= $&; K =:= $|; K =:= $!; K =:= $x; K =:= del;
	       K =:= $D; K =:= cut; K =:= $+ -> Ln > 0 andalso Added(Ln);
	{click, L, add} -> Added(L);
	{dclick, L, P} when P =/= handle -> Added(L);
	{move, F, T} -> Added(F) andalso Added(T);
	_ when K =:= alt_up; K =:= alt_down ->
	    {F, L} = span(S, D, Ln),
	    Ln > 0 andalso Added(F) andalso
		Added(case K of alt_up -> F - 1; alt_down -> L + 1 end);
	{paste, Text} -> (Ln > 0 andalso Added(Ln)) orelse is_rule(Text, S);
	_ -> true
    end.

is_rule(Text, #{doc := D}) ->
    element(1, caned_doc:insert_stmt(D, 1, Text)) =:= ok.

%% The rule on the cursor's line off, or on again.
switch(S = #{doc := D, ln := Ln, undo := Us}) when Ln > 0 ->
    Off = not caned_doc:off(D, Ln),
    {ok, S#{doc := caned_doc:set_off(D, Ln, Off), undo := [D | Us], redo := [],
	    msg := case Off of true -> "off: "; false -> "on: " end ++ copy(D, Ln, rule)}};
switch(S) -> {ok, S}.

key2({click, Ln, P}, S) ->
    {ok, maps:remove(free, S#{ln := Ln, cur := P, sel := none, msg := ""})};
key2({scroll, N}, S = #{top := Top}) -> {ok, S#{top := max(1, Top + N), free => true}};
key2(page_up, S) -> key2({scroll, -10}, S);
key2(page_down, S) -> key2({scroll, 10}, S);
key2({dclick, Ln, P}, S) -> {ok, start_edit(S#{ln := Ln, cur := P, sel := none})};
key2({select, Ln, Ps}, S = #{doc := D}) ->
    R = sel_range(tree(D, Ln), Ps),
    {ok, S#{ln := Ln, cur := hd(Ps), sel := {Ln, R},
	    msg := "selected: " ++ copy(D, Ln, R)}};
key2(copy, S = #{doc := D, ln := Ln}) when Ln > 0 ->
    {_, R} = target(S),
    Text = copy(D, Ln, R),
    {ok, S#{clip := Text, msg := "copied: " ++ Text}};
key2(cut, S = #{ln := Ln, cur := coil, sel := none}) when Ln > 0 ->
    {ok, S#{msg := "a coil is not cut alone -- select the rule"}};
key2(cut, S = #{doc := D, ln := Ln}) when Ln > 0 ->
    case target(S) of
	{_, rule} ->
	    Text = copy(D, Ln, rule),
	    {ok, S1} = normal($D, S#{sel := none}),
	    {ok, S1#{clip := Text, msg := "cut: " ++ Text}};
	{_, R} ->
	    T = tree(D, Ln),
	    Text = caned_tree:copy(T, R),
	    T1 = caned_tree:cut(T, R),
	    {ok, (change(T1, hd(caned_tree:leaves(T1)), S))#{clip := Text, sel := none,
							     msg := "cut: " ++ Text}}
    end;
%% A whole rule pasted onto a contact goes in as a rule of its own, after
%% this one -- in patch mode onto anything but what was added, at the end.
key2({paste, Text}, S = #{doc := D, ln := Ln, access := patch}) when Ln > 0 ->
    case caned_doc:added(D, Ln) of
	true -> paste(Text, S);
	false -> paste_rule(Text, caned_doc:last_line(D), S)
    end;
key2({paste, Text}, S = #{ln := Ln}) when Ln > 0 -> paste(Text, S);
key2(K, S = #{ln := 0, doc := D}) when K =:= $o; K =:= $O ->
    {ok, S#{mode := {coil, "", caned_doc:last_line(D)}, msg := ""}};
key2({paste, Text}, S = #{ln := 0, doc := D}) -> paste_rule(Text, caned_doc:last_line(D), S);
key2(K, S = #{ln := 0}) when K =:= $s; K =:= $q; K =:= $Q; K =:= $u; K =:= 18 ->
    normal(K, S#{msg := ""});
key2(_K, S = #{ln := 0}) -> {ok, S#{msg := "no rung in this file -- o makes one"}};
key2(K, S) when K =:= shift_right; K =:= shift_left -> normal(K, S#{msg := ""});
key2(K, S) -> normal(K, maps:without([anchor, free], S#{msg := "", sel := none})).

paste(Text, S = #{doc := D, ln := Ln}) ->
    {R, Rule} = case target(S) of
		    {_, rule} -> {caned_doc:set_stmt(D, Ln, Text), false};
		    {_, {coil, all}} -> {caned_doc:set_coil(D, Ln, Text), true};
		    {_, Rg} ->
			{case caned_tree:replace(tree(D, Ln), Rg, Text) of
			     {ok, T1} -> {ok, caned_doc:set_rung(D, Ln, T1)};
			     E -> E
			 end, true}
		end,
    case R of
	{ok, D1} -> {ok, fix_cur(doc_change(D1, S#{sel := none}))};
	{error, M} ->
	    case Rule andalso is_rule(Text, S) of
		true -> paste_rule(Text, Ln + 1, S);
		false -> {ok, S#{msg := "not pasted: " ++ M}}
	    end
    end.

paste_rule(Text, At, S = #{doc := D}) ->
    case caned_doc:insert_stmt(D, At, Text) of
	{ok, D1} ->
	    S1 = doc_change(D1, S#{sel := none}),
	    {ok, case caned_doc:rung(D1, At) of
		     none -> S1#{msg := "pasted as rule " ++ no(D1, At)};
		     _ -> S1#{ln := At, cur := first_leaf(D1, At)}
		 end};
	{error, M} -> {ok, S#{msg := "not pasted: " ++ M}}
    end.

no(D, Ln) ->
    case lists:keyfind(Ln, 1, caned_doc:numbers(D)) of
	{_, N} -> integer_to_list(N);
	false -> "?"
    end.

%% The range a set of contacts makes; with the coil among them, the rule.
sel_range(T, Ps) ->
    case lists:member(coil, Ps) of
	true -> rule;
	false -> caned_tree:range(T, Ps)
    end.

%% The selection as text, or none: what X11's PRIMARY gets.
sel_text(#{sel := {Ln, R}, doc := D}) -> copy(D, Ln, R);
sel_text(_) -> none.

copy(D, Ln, rule) -> caned_doc:print_rule(caned_doc:stmt(D, Ln));
copy(D, Ln, {coil, all}) -> caned_doc:coil_text(D, Ln);
copy(D, Ln, R) -> caned_tree:copy(tree(D, Ln), R).

doc_change(D1, S = #{doc := D, undo := Us}) ->
    S#{doc := D1, undo := [D | Us], redo := []}.

%% Shift + arrow: the selection grows from where it began (the anchor) to the
%% contact the cursor steps to -- the range those contacts make.
extend(K, S0 = #{doc := D, ln := Ln, cur := P}) ->
    A = maps:get(anchor, S0, P),
    S = step(case K of shift_right -> 1; shift_left -> -1 end, S0),
    #{cur := P1} = S,
    T = tree(D, Ln),
    Ls = caned_tree:leaves(T) ++ [coil],
    {I, J} = {index_in(Ls, A), index_in(Ls, P1)},
    Ps = lists:sublist(Ls, min(I, J), abs(I - J) + 1),
    R = sel_range(T, Ps),
    S#{anchor => A, sel := {Ln, R}, msg := "selected: " ++ copy(D, Ln, R)}.

%% What copy, cut and paste work on: the selection, or the contact under the
%% cursor.
target(#{sel := {Ln, R}, ln := Ln}) -> {Ln, R};
target(#{ln := Ln, cur := P}) -> {Ln, {P, all}}.

normal(right, S) -> {ok, step(1, S)};
normal(left, S)  -> {ok, step(-1, S)};
normal(K, S) when K =:= shift_right; K =:= shift_left -> {ok, extend(K, S)};
normal(down, S)  -> {ok, line(1, S)};
normal(up, S)    -> {ok, line(-1, S)};
normal(tab, S)   -> {ok, line(1, S)};
normal(shift_tab, S) -> {ok, line(-1, S)};
normal(enter, S) -> {ok, start_edit(S)};
normal($e, S)    -> {ok, start_edit(S)};
normal(K, S = #{cur := coil}) when K =:= $&; K =:= $|; K =:= $!; K =:= $x; K =:= del ->
    {ok, S#{msg := "on the coil: ⏎ writes it, ← to the contacts"}};
normal($&, S)    -> {ok, add(add_and, S)};
normal(K, S = #{access := patch, doc := D}) when K =:= $o; K =:= $O ->
    {ok, S#{mode := {coil, "", caned_doc:last_line(D)}}};
normal($o, S = #{ln := Ln}) -> {ok, S#{mode := {coil, "", Ln + 1}}};
normal($O, S = #{ln := Ln}) -> {ok, S#{mode := {coil, "", Ln}}};
normal($-, S) -> switch(S);
normal($D, S = #{doc := D, ln := Ln, undo := Us}) ->
    I = index_in(stops(D), Ln),
    D1 = caned_doc:delete_line(D, Ln),
    S1 = S#{doc := D1, undo := [D | Us], redo := []},
    {ok, case stops(D1) of
	     [] -> S1#{ln := 0, cur := []};
	     Rs -> L1 = lists:nth(min(I, length(Rs)), Rs),
		   S1#{ln := L1, cur := cur_for(D1, L1)}
	 end};
normal($|, S)    -> {ok, add(add_or, S)};
normal($!, S = #{doc := D, ln := Ln, cur := P}) ->
    {ok, change(caned_tree:negate(tree(D, Ln), P), P, S)};
normal(K, S = #{doc := D, ln := Ln, cur := P}) when K =:= $x; K =:= del ->
    T = tree(D, Ln),
    I = index(T, P),
    T1 = caned_tree:delete(T, P),
    {ok, change(T1, nth_leaf(T1, I), S)};
normal($u, S = #{undo := [D0 | Us], redo := Rs, doc := D}) ->
    {ok, fix_cur(S#{doc := D0, undo := Us, redo := [D | Rs]})};
normal($u, S) -> {ok, S#{msg := "nothing to undo"}};
normal(18, S = #{redo := [D1 | Rs], undo := Us, doc := D}) ->      % ^R
    {ok, fix_cur(S#{doc := D1, redo := Rs, undo := [D | Us]})};
normal(18, S) -> {ok, S#{msg := "nothing to redo"}};
normal($s, S = #{doc := D, file := F, ln := Ln}) ->
    case caned_doc:save(D, F) of
	ok ->
	    Ln1 = case Ln of 0 -> 0; _ -> caned_doc:saved_line(D, Ln) end,
	    {ok, S#{doc := caned_doc:saved(D), ln := Ln1, msg := "saved"}};
	{error, Why} -> {ok, S#{msg := "not saved: " ++ file:format_error(Why)}}
    end;
normal($q, S = #{doc := D}) ->
    case caned_doc:dirty(D) of
	true  -> {ok, S#{msg := "not saved -- s saves, Q quits anyway"}};
	false -> {quit, S}
    end;
normal($Q, S) -> {quit, S};
normal(_, S) -> {ok, S}.

%% The contact Dir steps away, in the order the contacts are drawn; the
%% coil after the last.
step(Dir, S = #{doc := D, ln := Ln, cur := P}) ->
    Ls = caned_tree:leaves(tree(D, Ln)) ++ [coil],
    I = max(1, min(length(Ls), index_in(Ls, P) + Dir)),
    S#{cur := lists:nth(I, Ls)}.

%% The rung Dir lines away, on the contact as far in as the cursor was.
line(Dir, S = #{doc := D, ln := Ln, cur := P}) ->
    Rs = stops(D),
    J = index_in(Rs, Ln) + Dir,
    case J >= 1 andalso J =< length(Rs) of
	true ->
	    L1 = lists:nth(J, Rs),
	    Cur = case {cur_for(D, L1), P} of
		      {comment, _} -> comment;
		      {{seg, _} = C, _} -> C;
		      {_, coil} -> coil;
		      {C, comment} -> C;
		      {C, {seg, _}} -> C;
		      _ -> nth_leaf(tree(D, L1), index(tree(D, Ln), P))
		  end,
	    S#{ln := L1, cur := Cur};
	false -> S
    end.

%% The new contact and what is written into it are one change: one undo, and
%% Esc takes the contact away again.
add(F, S = #{doc := D, ln := Ln, cur := P}) ->
    {T1, H} = caned_tree:F(tree(D, Ln), P),
    (start_edit(change(T1, H, S)))#{added => {Ln, P}}.

%% A new tree on the cursor's rung: the old document goes on the undo stack.
change(T, Cur, S = #{doc := D, ln := Ln, undo := Us}) ->
    S#{doc := caned_doc:set_rung(D, Ln, T), cur := Cur, undo := [D | Us],
       redo := []}.

%% After an undo or a redo the rung may have changed under the cursor, or
%% be gone.
fix_cur(S = #{doc := D, ln := Ln, cur := P}) ->
    Ns = stops(D),
    case {caned_doc:rung(D, Ln), Ns} of
	{none, []} -> S#{ln := 0, cur := []};
	{none, _} ->
	    case lists:member(Ln, Ns) of
		true ->
		    case {cur_for(D, Ln), P} of
			{{seg, _}, {seg, I}} -> S#{cur := {seg, min(I, length(fields(D, Ln)))}};
			{C, _} -> S#{cur := C}
		    end;
		false ->
		    L1 = lists:last([hd(Ns) | [R || R <- Ns, R =< Ln]]),
		    S#{ln := L1, cur := cur_for(D, L1)}
	    end;
	{{_, T}, _} ->
	    case lists:member(P, [coil | caned_tree:leaves(T)]) of
		true -> S;
		false -> S#{cur := hd(caned_tree:leaves(T))}
	    end
    end.

%%% ----------------------------------------------------------------- cards

%% The fields of the declaration on Ln, the keyword left out: [{Key, Sep, Text}].
fields(D, Ln) -> tl(caned_decl:segs(caned_doc:stmt(D, Ln))).

card_key(K, S = #{doc := D, ln := Ln, cur := {seg, I}}) when K =:= left; K =:= right ->
    N = length(fields(D, Ln)),
    {ok, S#{cur := {seg, max(1, min(N, I + case K of left -> -1; right -> 1 end))}}};
card_key(K, S = #{doc := D, ln := Ln, cur := {seg, I}}) when K =:= enter; K =:= $e ->
    case lists:nth(I, fields(D, Ln)) of
        {name, _, _} -> {ok, S#{msg := "the name is renamed with its uses -- not yet"}};
        {Key, _, T} -> {ok, S#{mode := {field, Key, "", T, 0}, msg := ""}}
    end;
card_key($+, S = #{doc := D, ln := Ln}) ->
    case caned_menu:add(caned_doc:stmt(D, Ln), D) of
        [] -> {ok, S#{msg := "nothing more goes on this one"}};
        _ -> {ok, S#{mode := {field, add, "", "", 0}, msg := ""}}
    end;
card_key(K, S = #{doc := D, ln := Ln, cur := {seg, I}}) when K =:= $x; K =:= del ->
    Fs = fields(D, Ln),
    case lists:nth(I, Fs) of
        {Key, _, _} when Key =:= arr; Key =:= res; Key =:= init; Key =:= transport;
                         element(1, Key) =:= opt ->
            set_fields(lists:keydelete(Key, 1, Fs), S#{cur := {seg, max(1, I - 1)}});
        _ -> {ok, S#{msg := "that one is not taken off"}}
    end;
card_key(copy, S = #{doc := D, ln := Ln}) ->
    T = string:trim(caned_doc:line(D, Ln)),
    {ok, S#{clip := T, msg := "copied: " ++ T}};
card_key(cut, S = #{doc := D, ln := Ln}) ->
    T = string:trim(caned_doc:line(D, Ln)),
    {ok, S1} = normal($D, S),
    {ok, S1#{clip := T, msg := "cut: " ++ T}};
card_key({paste, Text}, S = #{ln := Ln}) ->
    case is_rule(Text, S) of
        true -> paste_rule(Text, Ln + 1, S);
        false -> {ok, S#{msg := "not pasted: a declaration takes a rule after it, no more"}}
    end;
card_key(K, S) when K =:= shift_left; K =:= shift_right; K =:= $&; K =:= $|; K =:= $!;
                    K =:= $- ->
    {ok, S#{msg := "a declaration: ⏎ writes a field, + adds to it"}};
card_key(K, S) -> key2(K, S).

%% The declaration from its fields: {ok, S} with it in place, or the reason
%% it does not parse.
set_fields(Fs, S = #{doc := D, ln := Ln}) ->
    [Kw | _] = caned_decl:segs(caned_doc:stmt(D, Ln)),
    case caned_doc:set_decl(D, Ln, caned_decl:join([Kw | Fs])) of
        {ok, D1} ->
            N = length(fields(D1, Ln)),
            {seg, I} = maps:get(cur, S),
            {ok, (doc_change(D1, S))#{mode := normal, cur := {seg, max(1, min(N, I))}}};
        {error, M} -> {error, M}
    end.

%% Writing field Key (add: a new one): Typed what was typed, the choices
%% narrowed by it; Text what is in the field; Sel the choice Tab put in.
field(esc, _, _, _, _, S) -> {ok, S#{mode := normal, msg := ""}};
field(enter, Key, _, Text, _, S = #{doc := D, ln := Ln, cur := {seg, I}}) ->
    Fs = fields(D, Ln),
    {Fs1, I1} = case {Key, string:trim(Text)} of
                    {add, T} -> put_field(Fs, T);
                    {_, ""} -> {lists:keydelete(Key, 1, Fs), max(1, I - 1)};
                    {_, T} -> {lists:keyreplace(Key, 1, Fs,
                                                setelement(3, lists:keyfind(Key, 1, Fs), T)), I}
                end,
    case set_fields(Fs1, S#{cur := {seg, I1}}) of
        {ok, S1} -> {ok, S1};
        {error, M} -> {ok, S#{msg := M}}
    end;
field(backspace, Key, _, Text, _, S) when Text =/= "" ->
    T = lists:droplast(Text),
    {ok, S#{mode := {field, Key, T, T, 0}}};
field(K, Key, Typed, Text, Sel, S) when K =:= tab; K =:= down; K =:= shift_tab; K =:= up ->
    case choices(Key, Typed, S) of
        [] -> {ok, S};
        Cs ->
            N = length(Cs),
            At = case Sel of 0 -> index_of(Text, Cs); _ -> Sel end,
            Sel1 = case At of
                       0 when K =:= tab; K =:= down -> 1;
                       0 -> N;
                       _ when K =:= tab; K =:= down -> At rem N + 1;
                       _ -> (At + N - 2) rem N + 1
                   end,
            {ok, S#{mode := {field, Key, Typed, lists:nth(Sel1, Cs), Sel1}}}
    end;
field(C, Key, _, Text, _, S) when is_integer(C), C >= $\s ->
    T = Text ++ [C],
    {ok, S#{mode := {field, Key, T, T, 0}, msg := ""}};
field(_, _, _, _, _, S) -> {ok, S}.

index_of(X, L) ->
    case lists:search(fun({_, Y}) -> Y =:= X end, lists:enumerate(L)) of
        {value, {I, _}} -> I;
        false -> 0
    end.

%% What can go in field Key, narrowed by what was typed.
choices(Key, Typed, #{doc := D, ln := Ln}) ->
    St = caned_doc:stmt(D, Ln),
    Cs = case Key of
             add -> caned_menu:add(St, D);
             _ -> caned_menu:field(St, Key, D)
         end,
    [C || C <- Cs, lists:prefix(Typed, C)].

%% A new field where it belongs: `:N' the width, a transport last, an option
%% after the others. {Fields, its index}.
put_field(Fs, ":" ++ W) -> after_keys(Fs, {res, ":", W}, [name, arr]);
put_field(Fs, T) ->
    case lists:member(hd(string:lexemes(T ++ " ", " ")),
                      ["can", "tcp", "udp", "uart", "console", "repl", "sms", "i2c", "spi",
                       "onewire"]) of
        true -> {Fs ++ [{transport, " ", T}], length(Fs) + 1};
        false -> after_keys(Fs, {{opt, 0}, " ", T}, [name, arr, res, opt])
    end.

after_keys(Fs, New, Keys) ->
    In = fun({K, _, _}) -> lists:member(K, Keys) orelse
                               (is_tuple(K) andalso lists:member(element(1, K), Keys)) end,
    {A, B} = lists:splitwith(In, Fs),
    {A ++ [New | B], length(A) + 1}.

%%% -------------------------------------------------------------- comments

comment_key(K, S = #{doc := D, ln := Ln}) when K =:= enter; K =:= $e ->
    {_, _, _, Ls} = caned_doc:comment_at(D, Ln),
    Text = lists:flatten(lists:join("\n", Ls)),
    {ok, S#{mode := {note, Text, length(Text), {at, Ln}}, msg := ""}};
comment_key(K, S = #{doc := D, ln := Ln}) when K =:= $D; K =:= $x; K =:= del; K =:= cut ->
    {F, L, _, _} = caned_doc:comment_at(D, Ln),
    Text = comment_text(D, Ln),
    S1 = fix_cur(doc_change(caned_doc:delete_lines(D, F, L), S#{sel := none})),
    {ok, case K of
             cut -> S1#{clip := Text, msg := "cut: the comment"};
             _ -> S1
         end};
comment_key(copy, S = #{doc := D, ln := Ln}) ->
    {ok, S#{clip := comment_text(D, Ln), msg := "copied: the comment"}};
comment_key({paste, Text}, S = #{doc := D, ln := Ln}) ->
    {_, L, _, _} = caned_doc:comment_at(D, Ln),
    case is_rule(Text, S) of
        true -> paste_rule(Text, L + 1, S);
        false -> {ok, S#{msg := "not pasted: a comment takes a rule after it, no more"}}
    end;
comment_key(K, S) when K =:= left; K =:= right; K =:= shift_left; K =:= shift_right;
                       K =:= $&; K =:= $|; K =:= $!; K =:= $- ->
    {ok, S#{msg := "a comment: ⏎ writes it, D takes it out"}};
comment_key(K, S) -> key2(K, S).

%% The comment as its lines read in the file.
comment_text(D, Ln) ->
    {F, L, _, _} = caned_doc:comment_at(D, Ln),
    lists:flatten(lists:join("\n", [caned_doc:line(D, N) || N <- lists:seq(F, L)])).

%% Writing a comment: Text and the caret's place in it (At, characters
%% before it). Where: {at, First} a comment there, {new, Line} a new one.
note(esc, _, _, _, S) -> {ok, S#{mode := normal, msg := ""}};
note(enter, Text, _, Where, S = #{doc := D}) ->
    Ls = string:split(Text, "\n", all),
    {D1, Ln} = case Where of
                   {at, F} -> {caned_doc:set_comment(D, F, Ls), F};
                   {new, At} -> {caned_doc:new_comment(D, At, Ls), At}
               end,
    S1 = doc_change(D1, S#{mode := normal}),
    {ok, case caned_doc:comment_at(D1, Ln) of
             {Ln, _, _, _} -> S1#{ln := Ln, cur := comment};
             _ when Where =:= {new, Ln} -> S1;              % nothing written
             _ -> fix_cur(S1)
         end};
note(newline, Text, At, W, S) -> note_put("\n", Text, At, W, S);
note(backspace, _Text, 0, _, S) -> {ok, S};
note(backspace, Text, At, W, S) ->
    {A, [_ | B]} = lists:split(At - 1, Text),
    {ok, S#{mode := {note, A ++ B, At - 1, W}}};
note(del, Text, At, W, S) when At < length(Text) ->
    {A, [_ | B]} = lists:split(At, Text),
    {ok, S#{mode := {note, A ++ B, At, W}}};
note(left, Text, At, W, S) -> {ok, S#{mode := {note, Text, max(0, At - 1), W}}};
note(right, Text, At, W, S) -> {ok, S#{mode := {note, Text, min(length(Text), At + 1), W}}};
note(K, Text, At, W, S) when K =:= up; K =:= down ->
    {ok, S#{mode := {note, Text, vertical(K, Text, At), W}}};
note(C, Text, At, W, S) when is_integer(C), C >= $\s -> note_put([C], Text, At, W, S);
note(_, _, _, _, S) -> {ok, S}.

note_put(Cs, Text, At, W, S) ->
    {A, B} = lists:split(At, Text),
    {ok, S#{mode := {note, A ++ Cs ++ B, At + length(Cs), W}, msg := ""}}.

%% The caret a line up or down, as far in as it was.
vertical(K, Text, At) ->
    Ls = string:split(Text, "\n", all),
    Starts = lists:droplast(lists:foldl(fun(L, [S | _] = Acc) -> [S + length(L) + 1 | Acc] end,
                                        [0], Ls)),
    St = lists:reverse(Starts),
    I = length([S || S <- St, S =< At]),
    Col = At - lists:nth(I, St),
    J = case K of up -> I - 1; down -> I + 1 end,
    case J >= 1 andalso J =< length(Ls) of
        true -> lists:nth(J, St) + min(Col, length(lists:nth(J, Ls)));
        false -> At
    end.

%%% ------------------------------------------------------------- new rungs

coil_key(esc, _Text, _At, S) -> {ok, S#{mode := normal, msg := ""}};
coil_key(enter, Text, At, S = #{doc := D, ln := Ln, cur := P, undo := Us}) ->
    case caned_doc:new_rung(D, At, string:trim(Text)) of
	{ok, D1} ->
	    S1 = S#{doc := D1, undo := [D | Us], redo := [], ln := At, cur := []},
	    {ok, (start_edit(S1))#{added => {Ln, P}}};
	{error, M} -> {ok, S#{msg := M}}
    end;
coil_key(backspace, "", _At, S) -> {ok, S};
coil_key(backspace, Text, At, S) -> {ok, S#{mode := {coil, lists:droplast(Text), At}}};
coil_key(C, Text, At, S) when is_integer(C), C > $\s ->
    {ok, S#{mode := {coil, Text ++ [C], At}, msg := ""}};
coil_key(_, _Text, _At, S) -> {ok, S}.

index(T, P) -> index_in(caned_tree:leaves(T), P).

index_in(L, X) -> index_in(L, X, 1).
index_in([X | _], X, I) -> I;
index_in([_ | T], X, I) -> index_in(T, X, I + 1);
index_in([], _, _) -> 1.

nth_leaf(T, I) ->
    Ls = caned_tree:leaves(T),
    lists:nth(max(1, min(I, length(Ls))), Ls).

%%% --------------------------------------------------------------- writing

start_edit(S = #{doc := D, ln := Ln, cur := coil}) ->
    S#{mode := {edit_coil, caned_doc:coil_text(D, Ln)}};
start_edit(S = #{doc := D, ln := Ln, cur := P}) ->
    Text = case caned_tree:get(tree(D, Ln), P) of
	       {leaf, {hole, _}} -> "";
	       N -> caned_tree:text(N)
	   end,
    S#{mode := {edit, Text}}.

edit_coil(esc, _Text, S) -> {ok, S#{mode := normal, msg := ""}};
edit_coil(enter, Text, S = #{doc := D, ln := Ln}) ->
    case caned_doc:set_coil(D, Ln, string:trim(Text)) of
	{ok, D1} -> {ok, (doc_change(D1, S))#{mode := normal}};
	{error, M} -> {ok, S#{msg := M}}
    end;
edit_coil(backspace, "", S) -> {ok, S};
edit_coil(backspace, Text, S) -> {ok, S#{mode := {edit_coil, lists:droplast(Text)}}};
edit_coil(C, Text, S) when is_integer(C), C >= $\s ->
    {ok, S#{mode := {edit_coil, Text ++ [C]}, msg := ""}};
edit_coil(_, _Text, S) -> {ok, S}.

edit(esc, _Text, S = #{added := {L0, P0}, undo := [D0 | Us]}) ->
    {ok, maps:remove(added, S#{doc := D0, undo := Us, ln := L0, cur := P0,
			       mode := normal, msg := ""})};
edit(esc, _Text, S) -> {ok, S#{mode := normal, msg := ""}};
edit(enter, Text, S = #{doc := D, ln := Ln, cur := P}) ->
    T = tree(D, Ln),
    case caned_tree:set_text(T, P, Text) of
	{ok, T1} ->
	    Cur = nth_leaf(T1, index(T, P)),
	    S1 = case S of
		     %% What was added and what is written in it are one change:
		     %% the undo stack already holds the document before both.
		     #{added := _} -> S#{doc := caned_doc:set_rung(D, Ln, T1), cur := Cur};
		     _ -> change(T1, Cur, S)
		 end,
	    {ok, maps:remove(added, S1#{mode := normal})};
	{error, M} -> {ok, S#{msg := M}}
    end;
edit(tab, Text, S) ->
    case parts_at(Text, S) of
        none -> {ok, S};
        {Base, Part, Ps} ->
            Next = case lists:dropwhile(fun(P) -> P =/= Part end, Ps) of
                       [_, N | _] -> N;
                       _ -> case [P || P <- Ps, lists:prefix(Part, P)] of
                                [P | _] -> P;
                                [] -> hd(Ps)
                            end
                   end,
            {ok, S#{mode := {edit, Base ++ Next}}}
    end;
edit(backspace, "", S) -> {ok, S};
edit(backspace, Text, S) -> {ok, S#{mode := {edit, lists:droplast(Text)}}};
edit(C, Text, S) when is_integer(C), C >= $\s ->
    {ok, S#{mode := {edit, Text ++ [C]}, msg := ""}};
edit(_, _Text, S) -> {ok, S}.

%% `... Name.part' at the end of what is written, Name declared with parts:
%% {the text up to the dot, the part written so far, the parts} | none.
parts_at(Text, #{doc := D}) ->
    case re:run(Text, "([A-Za-z][A-Za-z0-9_]*)\\.([A-Za-z]*)$", [{capture, all, list}]) of
        {match, [All, Name, Part]} ->
            case caned_menu:parts(caned_menu:kind_of(D, Name)) of
                [] -> none;
                Ps -> {lists:sublist(Text, length(Text) - length(All)) ++ Name ++ ".", Part, Ps}
            end;
        nomatch -> none
    end.

%%% ---------------------------------------------------------------- screen

%% Rows by Cols: the file from the top line, the status line last. The view
%% scrolls to keep the cursor's rung in it.
screen(S0, Rows, Cols) ->
    S = scroll(S0, Rows - 1),
    {Body, _} = body(S),
    #{top := Top} = S,
    View = lists:sublist(lists:nthtail(min(Top - 1, length(Body)), Body), Rows - 1),
    Pad = lists:duplicate(Rows - 1 - length(View), [{blank, ""}]),
    {S, [clip(R, Cols) || R <- View ++ Pad] ++ [clip(status(S), Cols)]}.

%% The screen as plain text: what a test compares.
plain(S, Rows, Cols) ->
    {_, Rs} = screen(S, Rows, Cols),
    [string:trim(lists:append([T || {_, T} <- R]), trailing) || R <- Rs].

%% Every line's rows, and the row each line starts on.
body(S = #{doc := D}) ->
    N = caned_doc:nlines(D),
    Rungs = rungs(D),
    Width = lists:max([0 | [W || L <- Rungs,
				 {W, _, _, _} <- [caned_grid:el(shown(S, L), none)]]]),
    CoilW = lists:max([0 | [length(caned_doc:coil_text(D, L)) || L <- Rungs]]),
    Nos = maps:from_list(caned_doc:numbers(D)),
    Cs = maps:from_list([{X, {F, L}} || {F, L, _, _} <- caned_doc:comments(D),
					X <- lists:seq(F, L)]),
    {Rows, Starts} =
	lists:foldl(
	  fun(L, {Acc, St}) ->
		  Rs = case note_rows(S, L) of
			   none -> line_rows(S, L, {Width, CoilW}, Nos, Cs);
			   Ns -> Ns
		       end,
		  {Acc ++ Rs, St#{L => length(Acc) + 1}}
	  end, {[], #{}}, lists:seq(1, N)),
    case note_rows(S, N + 1) of
	none -> {Rows, Starts};
	More -> {Rows ++ More, Starts#{N + 1 => length(Rows) + 1}}
    end.

%% A comment being written, as it will be saved, the caret in it: in place
%% of the comment's lines, or above line At for a new one. none elsewhere.
note_rows(S = #{mode := {note, Text, At, Where}, doc := D}, L) ->
    Ls = maps:get(lines, D),
    Line = fun(N) when N =< length(Ls) -> lists:nth(N, Ls); (_) -> "" end,
    Edited = fun(Ref) ->
		     {A, B} = lists:split(At, Text),
		     Indent = indent(Ref),
		     Ts = [R || T <- string:split(A ++ "▏" ++ B, "\n", all),
				R <- caned_doc:wrap_text(Indent, T, 80)],
		     Box = box(Indent, box_width(Indent, Ts), frame_edit, note, none),
		     [Box(top)] ++ [Box({text, T}) || T <- Ts] ++ [Box(bottom)]
	     end,
    case Where of
	{at, L} -> Edited(Line(L));
	{at, F} ->
	    {F, Last, _, _} = caned_doc:comment_at(D, F),
	    case L > F andalso L =< Last of
		true -> [];
		false -> none
	    end;
	{new, L} ->
	    Ref = case string:trim(Line(L)) of "" -> Line(L - 1); _ -> Line(L) end,
	    case L > length(Ls) of
		true -> Edited(Ref);
		false -> Edited(Ref) ++ line_rows(S#{mode := normal}, L)
	    end;
	_ -> none
    end;
note_rows(_, _) -> none.

%% A comment as a box with a double frame, as wide as its lines are let be
%% when saved: Box(top | {text, T} | bottom) a row of it.
box(Indent, W, Frame, Ink, Path) ->
    A = fun(X) when Path =:= none -> X; (X) -> {X, Path} end,
    fun(top) -> [{lineno, "     "}, {text, Indent}, {A(Frame), "╔" ++ lists:duplicate(W + 2, $═) ++ "╗"}];
       (bottom) -> [{lineno, "     "}, {text, Indent}, {A(Frame), "╚" ++ lists:duplicate(W + 2, $═) ++ "╝"}];
       ({text, T}) ->
            [{lineno, "     "}, {text, Indent}, {A(Frame), "║"},
             {A(Ink), " " ++ T ++ lists:duplicate(W - length(T), $\s) ++ " "}, {A(Frame), "║"}]
    end.

box_width(Indent, Ts) -> lists:max([caned_doc:text_width(Indent, 80) | [length(T) || T <- Ts]]).

indent(L) -> lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, L).

%% One line's rows by itself (under a new comment being written).
line_rows(S = #{doc := D}, L) ->
    Rungs = rungs(D),
    Width = lists:max([0 | [W || R <- Rungs, {W, _, _, _} <- [caned_grid:el(shown(S, R), none)]]]),
    CoilW = lists:max([0 | [length(caned_doc:coil_text(D, R)) || R <- Rungs]]),
    Cs = maps:from_list([{X, {F, La}} || {F, La, _, _} <- caned_doc:comments(D),
					 X <- lists:seq(F, La)]),
    line_rows(S, L, {Width, CoilW}, maps:from_list(caned_doc:numbers(D)), Cs).

%% Left of a line its rule's number, a mark after it: ✕ off, + added (in
%% patch mode).
line_rows(S = #{doc := D, ln := Cur}, L, {Width, CoilW}, Nos, Cs) ->
    Off = caned_doc:off(D, L),
    Mark = if Off -> "✕";
	      true -> case maps:get(access, S) =:= patch andalso caned_doc:added(D, L) of
			  true -> "+";
			  false -> " "
		      end
	   end,
    No = case maps:find(L, Nos) of
	     {ok, N} -> lists:flatten(string:pad(integer_to_list(N), 4, leading)) ++ Mark;
	     error -> "     "
	 end,
    NoA = case Off of true -> lineno_off; false -> lineno end,
    case caned_doc:rung(D, L) of
	none when is_map_key(L, Cs) ->
	    {F, La} = maps:get(L, Cs),
	    {F, La, _, Ts} = caned_doc:comment_at(D, F),
	    Frame = case {F, maps:get(cur, S)} of
			{Cur, comment} -> frame_cur;
			_ -> frame
		    end,
	    Indent = indent(lists:nth(F, maps:get(lines, D))),
	    W = box_width(Indent, Ts),
	    Box = box(Indent, W, Frame, comment, {F, comment}),
	    [Box(top) || L =:= F] ++ [Box({text, lists:nth(L - F + 1, Ts)})] ++
		[Box(bottom) || L =:= La];
	none ->
	    case caned_doc:stmt(D, L) of
		none -> [[{NoA, No}, {text, caned_doc:line(D, L)}]];
		St -> [[{NoA, No} | card_row(S, L, St)]]
	    end;
	{_, _} ->
	    P = case L of Cur -> maps:get(cur, S); _ -> none end,
	    Sel = case maps:get(sel, S) of {L, R} -> R; _ -> none end,
	    E = caned_grid:rung(shown(S, L), caned_doc:coil_text(D, L), P, Sel, Width, CoilW),
	    %% A contact's cells say which rung they are on as well, for a click;
	    %% an off rule's are dim.
	    Dim = fun(A) when Off -> dim(A); (A) -> A end,
	    Ln = fun({A, Pa}) when is_list(Pa) -> {Dim(A), {L, Pa}};
		    ({A, coil}) -> {Dim(A), {L, coil}};
		    (A) -> Dim(A)
		 end,
	    [Row1 | More] = [[{Ln(A), T} || {A, T} <- Row] || Row <- caned_grid:rows(E)],
	    Trail = case caned_doc:trailing(D, L) of
			none -> [];
			C -> [{comment, "  " ++ C}]
		    end,
	    [[{{NoA, {L, handle}}, No} | Row1] ++ Trail | [[{lineno, "     "} | R] || R <- More]]
    end.

%% A declaration as its card: the keyword, each field on its own; the one
%% being written as it is so far.
card_row(S = #{doc := D, ln := Cur, mode := Mode}, L, St) ->
    [{kw, Kw} | _] = [{kw, T} || {kw, _, T} <- caned_decl:segs(St)],
    Fs = tl(caned_decl:segs(St)),
    Line = caned_doc:line(D, L),
    Indent = lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, Line),
    CI = case {L, maps:get(cur, S)} of
             {Cur, {seg, I}} -> I;
             _ -> none
         end,
    Edit = case {CI, Mode} of
               {none, _} -> none;
               {_, {field, K, _, T, _}} -> {K, T};
               _ -> none
           end,
    Field = fun(I, Key, T) ->
                    case Edit of
                        {Key, Te} when Key =/= add -> {{field_edit, {L, {seg, I}}}, Te ++ "▏"};
                        _ when I =:= CI -> {{field_cur, {L, {seg, I}}}, T};
                        _ -> {{field, {L, {seg, I}}}, T}
                    end
            end,
    [{text, Indent}, {kw, Kw}] ++
        lists:append([[{text, Sep} || Sep =/= ""] ++ [Field(I, Key, T)]
                      || {I, {Key, Sep, T}} <- lists:enumerate(Fs)]) ++
        case {Edit, CI} of
            {{add, Ta}, _} -> [{text, " "}, {field_edit, Ta ++ "▏"}];
            {_, none} -> [];
            _ -> [{{add, {L, add}}, " +"}]
        end ++
        case caned_doc:trailing(D, L) of
            none -> [];
            C -> [{comment, "  " ++ C}]
        end.

dim(contact) -> off;
dim(coil) -> coil_off;
dim(A) -> A.

%% The rung as it is shown: being written, what is typed so far.
shown(#{doc := D, ln := L, cur := P, mode := {edit, Text}}, L) ->
    T = tree(D, L),
    case caned_tree:set_text(T, P, Text) of
	{ok, T1} -> T1;
	_ -> T
    end;
shown(#{doc := D}, L) -> tree(D, L).

%% Scrolled by hand: no further than the last page filling the screen.
scroll(S = #{free := true, top := Top}, H) ->
    {Body, _} = body(S),
    S#{top := max(1, min(Top, length(Body) - H + 1))};
scroll(S = #{ln := 0}, _H) -> S;
scroll(S = #{ln := Ln, top := Top}, H) ->
    {Body, Starts} = body(S),
    First = maps:get(Ln, Starts),
    Last = case maps:find(Ln + 1, Starts) of
	       {ok, Nx} -> Nx - 1;
	       error -> length(Body)
	   end,
    Top1 = if First < Top -> First;
	      Last > Top + H - 1 -> max(1, Last - H + 1);
	      true -> Top
	   end,
    S#{top := Top1}.

status(#{mode := {coil, Text, _}, msg := M}) ->
    [{status, " new rung, its coil: "}, {edit, Text ++ "▏"}] ++
	[{error, "   " ++ M} || M =/= ""];
status(#{mode := {edit_coil, Text}, msg := M}) ->
    [{status, " coil: "}, {edit, Text ++ "▏"}] ++ [{error, "   " ++ M} || M =/= ""];
status(#{mode := {note, _, _, _}}) ->
    [{status, " comment: "}, {help, "⇧⏎ or ^J a new line   ⏎ done   Esc leave it as it was"}];
status(S = #{mode := {field, Key, Typed, Text, _}, msg := M}) ->
    Name = case Key of
               add -> "add";
               {opt, _} -> "option";
               _ -> atom_to_list(Key)
           end,
    [{status, " " ++ Name ++ ": "}, {edit, Text ++ "▏"}, {help, "  "}] ++
        [{case C of Text -> menu_sel; _ -> menu end, " " ++ C ++ " "}
         || C <- choices(Key, Typed, S)] ++
        [{error, "   " ++ M} || M =/= ""];
status(S = #{mode := {edit, Text}, msg := M}) when M =:= "" ->
    [{status, " write: "}, {edit, Text ++ "▏"}] ++
        case parts_at(Text, S) of
            none -> [];
            {_, _, Ps} -> [{help, "   Tab:"} | [{menu, " " ++ P} || P <- Ps]]
        end;
status(#{mode := {edit, Text}, msg := M}) ->
    [{status, " write: "}, {edit, Text ++ "▏"}] ++
	[{error, "   " ++ M} || M =/= ""];
status(#{file := F, doc := D, msg := M, access := A}) ->
    Dirty = case caned_doc:dirty(D) of true -> " *"; false -> "" end,
    [{status, " " ++ filename:basename(F) ++ Dirty ++ " [" ++ atom_to_list(A) ++ "]  "}] ++
	case M of
	    "" -> [{help, ?HELP}];
	    _ -> [{msg, M}]
	end.

%% No wider than the screen.
clip(Runs, Cols) -> clip(Runs, Cols, []).

clip([], _, Acc) -> lists:reverse(Acc);
clip(_, 0, Acc) -> lists:reverse(Acc);
clip([{A, T} | R], N, Acc) when length(T) =< N -> clip(R, N - length(T), [{A, T} | Acc]);
clip([{A, T} | _], N, Acc) -> lists:reverse([{A, lists:sublist(T, N)} | Acc]).
