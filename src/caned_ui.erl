%%% caned's editor without a terminal: a state, a key at a time, and the
%%% screen as rows of {Attr, String} runs. caned_tty puts those on a
%%% terminal; the tests read them as text.
%%%
%%% The cursor is on a contact of a rung (a line number and a path in its
%%% tree). Keys:
%%%
%%%   ← →        the contact before, after      ↑ ↓   the rung above, below
%%%   ⇧← ⇧→      select from here on            Tab ⇧Tab  the next, the last cell
%%%   PgUp PgDn  a page up, down (`page' rows)  Home End  the first, the last line
%%%   Insert     a new rung after (as o)        (rung_start, rung_end: the first
%%%                                              contact, the coil -- Emacs's C-a C-e)
%%%
%%% The coil is the last stop to the right (its path `coil'): ⏎ writes it --
%%% the target of `X = <condition>', the assignments of the rest. A selection
%%% that takes the coil is the whole rule: copied as its line, cut as it.
%%%   ⏎ or e     write the contact anew         &     a contact in series
%%%   |          a branch in parallel           !     normally closed / open
%%%   x or Del   the contact out                u     undo, ^R redo
%%%   o O        a new rung after, before       D     the rung out
%%%   -          the rule off (#disable), on    ⌥↑ ⌥↓ the rule a line up, down
%%%   Space      the next rung (on an object's line: open, close it)
%%%   #          a new line after: a declaration, #module ..., written in
%%%              the status line (not in patch mode)
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
%%% EMBEDDED (embedded => true, as candid's code view has it): s does not
%%% write the file, it is {save, S} for the host to save as it saves; q is
%%% the host's to do, not the editor's. key/2 then answers {ok, S} | {save, S}.
%%%
%%% OBJECTS. An object's line (`#Cnt c0') opens: under it its module's rungs
%%% as that object runs them, indented, lit for it -- a line key {in, O,
%%% Line} where the module's own line is Line, so lights/2 can tell whose
%%% they are. Space on the line or a click on its ▸ opens and closes it; a
%%% click on a rung shown under it goes to that rung in the module, to be
%%% written there. Only the rules: the module's declarations stay where they
%%% are.
%%%
%%% SCOPE. scope => all (the default) shows the whole file; {module, M}
%%% only module M, from its #module (and a comment right above it) to its
%%% #end -- an object's tab in candid. The cursor stays in it.
%%%
%%% LIGHTS. In candid the rungs are lit by what holds: an optional fun in the
%%% state, lights => fun(Ln, What) -> Light, asked for every contact (What
%%% {contact, Expr}: true | false | unknown), every coil (coil: fired | next | both |
%%% none) and every rung (row: on | off, off when its #in/#when block is not in
%%% force). csp_code makes it from what the program does; standalone there is
%%% none and nothing is lit. The cursor and a selection outshine a light.
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
%%% A new rung asks for its coil first -- a name, the coil that follows its
%%% condition, or assignments (`B = 1'), done when it holds -- then its
%%% condition is written: the two are one change, and Esc on either leaves
%%% no rung behind.

-module(caned_ui).

-export([new/2, new/3, open/1, open/2, key/2, screen/3, plain/3, sel_text/1]).
-export([height/1, all/1, light/2, set_scope/2]).

-define(HELP, "←→ contact  ↑↓ rung  ⏎ write  & series  | parallel  "
	"! not  x out  o new  # line  / comment  D out  - off/on  ⌥↑↓ move  u undo  s save  q quit").
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
    case stops(D) of                    % at the top: the first line that is a stop
	[L | _] -> S#{ln := L, cur := cur_for(D, L)};
	[] -> S
    end.

rungs(D) -> [N || N <- lists:seq(1, caned_doc:nlines(D)), caned_doc:rung(D, N) =/= none].

%% The lines shown: {First, Last}.
lines(S = #{doc := D}) ->
    N = caned_doc:nlines(D),
    case maps:get(scope, S, all) of
        {module, M} ->
            case module_span(D, M) of
                none -> {1, N};
                {F, L} -> {case caned_doc:comment_at(D, F - 1) of
                               {C, _, _, _} -> C;
                               none -> F
                           end, L}
            end;
        all -> {1, N}
    end.

%% Module M's #module line to its #end.
module_span(D, M) ->
    case lists:dropwhile(fun(St) -> not is_module(St, M) end, caned_doc:stmts(D)) of
        [St | Rest] -> {caned_doc:line_of(St), end_of(Rest, 0, caned_doc:nlines(D))};
        [] -> none
    end.

end_of([E = {'end', _} | _], 0, _) -> caned_doc:line_of(E);
end_of([St | Rest], Depth, N) ->
    end_of(Rest, case element(1, St) of
                     'end' -> Depth - 1;
                     K when K =:= in; K =:= 'when' -> Depth + 1;
                     _ -> Depth
                 end, N);
end_of([], _, N) -> N.

%% What is shown set to Scope, the cursor put in it when it was not.
set_scope(S, Scope) ->
    S1 = S#{scope => Scope},
    {F, L} = lines(S1),
    case {maps:get(ln, S1), shown_stops(S1)} of
        {_, []} -> S1;
        {Ln, _} when Ln >= F, Ln =< L -> S1;
        {_, [L1 | _]} -> S1#{ln := L1, cur := cur_for(maps:get(doc, S1), L1), sel := none}
    end.

%% The cursor moved by page_up | page_down (a page of rows, the state's
%% `page', the stop nearest that far), doc_start | doc_end (the first, the
%% last stop shown), rung_start | rung_end (the first contact, the coil; a
%% card's first and last field).
go(next_rung, S = #{doc := D, ln := Ln}) ->
    {F, L} = lines(S),
    case [X || X <- rungs(D), X > Ln, X >= F, X =< L] of
        [X | _] -> S#{ln := X, cur := first_leaf(D, X)};
        [] -> S
    end;
go(K, S = #{doc := D, ln := Ln}) when K =:= doc_start; K =:= doc_end ->
    case shown_stops(S) of
        [] -> S;
        Ns -> L1 = case K of doc_start -> hd(Ns); doc_end -> lists:last(Ns) end,
              case L1 of Ln -> S; _ -> S#{ln := L1, cur := cur_for(D, L1)} end
    end;
go(_K, S = #{ln := 0}) -> S;
go(K, S = #{doc := D, ln := Ln, cur := C}) when K =:= rung_start; K =:= rung_end ->
    case {C, K} of
        {comment, _} -> S;
        {{seg, _}, rung_start} -> S#{cur := {seg, 1}};
        {{seg, _}, rung_end} -> S#{cur := {seg, max(1, length(fields(D, Ln)))}};
        {_, rung_start} -> S#{cur := first_leaf(D, Ln)};
        {_, rung_end} -> S#{cur := coil}
    end;
go(K, S = #{doc := D, ln := Ln}) ->
    Dir = case K of page_up -> -1; page_down -> 1 end,
    {_, Starts} = body(S),
    Ns = shown_stops(S),
    Row = maps:get(Ln, Starts, 1),
    To = Row + Dir * maps:get(page, S, 20),
    Near = lists:sort([{abs(maps:get(L, Starts, 1) - To), L} || L <- Ns]),
    L1 = case Near of
             [{_, Ln} | _] -> lists:nth(max(1, min(length(Ns), index_in(Ns, Ln) + Dir)), Ns);
             [{_, L} | _] -> L;
             [] -> Ln
         end,
    S#{ln := L1, cur := cur_for(D, L1)}.

%% The cell Dir from the cursor's, over the line's end to the next line's
%% first cell (the last one's, back).
cell(_Dir, S = #{ln := 0}) -> S;
cell(Dir, S = #{doc := D, ln := Ln, cur := C}) ->
    Cs = cells(D, Ln),
    I = index_in(Cs, C) + Dir,
    case I >= 1 andalso I =< length(Cs) andalso lists:member(C, Cs) of
        true -> S#{cur := lists:nth(I, Cs)};
        false ->
            Ns = shown_stops(S),
            J = index_in(Ns, Ln) + Dir,
            case J >= 1 andalso J =< length(Ns) of
                true ->
                    L1 = lists:nth(J, Ns),
                    C1 = case Dir of 1 -> hd(cells(D, L1)); -1 -> lists:last(cells(D, L1)) end,
                    S#{ln := L1, cur := C1};
                false -> S
            end
    end.

%% A line's cells, left to right: a rung's contacts and its coil, a card's
%% fields, a comment as one.
cells(D, Ln) ->
    case {caned_doc:rung(D, Ln), cur_for(D, Ln)} of
        {none, comment} -> [comment];
        {none, {seg, _}} -> [{seg, I} || I <- lists:seq(kw_cell(D, Ln),
                                                         max(1, length(fields(D, Ln))))];
        {_, _} -> caned_tree:leaves(tree(D, Ln)) ++ [coil]
    end.

%% The stops in the lines shown.
shown_stops(S = #{doc := D}) ->
    {F, L} = lines(S),
    [X || X <- stops(D), X >= F, X =< L].

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
%% Tab going round a menu's choices (complete/3) stops at any other key.
key(K, S = #{cycle := _}) when K =/= tab, K =/= shift_tab -> key(K, maps:remove(cycle, S));
key({msg, M}, S) -> {ok, S#{msg := M}};          % what the keys say: `C-x-'
key(K, S = #{mode := {edit, Text}}) -> edit(K, Text, S);
key(K, S = #{mode := {edit_coil, Text}}) -> edit_coil(K, Text, S);
key(K, S = #{mode := {coil, Text, At}}) -> coil_key(K, Text, At, S);
key(K, S = #{mode := {stmt, Text, At}}) -> stmt_key(K, Text, At, S);
key(K, S = #{mode := {declare, N, Near}}) -> declare_key(K, N, Near, S);
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
key1(K, S) when K =:= page_up; K =:= page_down; K =:= doc_start; K =:= doc_end;
                K =:= rung_start; K =:= rung_end ->
    {ok, maps:without([anchor, free], go(K, S#{msg := "", sel := none}))};
%% Space: an object's line opened or closed; anywhere else the next rung --
%% from the top, where the editor starts, the first rule.
key1($\s, S = #{doc := D, ln := Ln}) ->
    case caned_doc:stmt(D, Ln) of
        {object, _, _, _, _} -> toggle_open(S, Ln);
        _ -> {ok, maps:without([anchor, free], go(next_rung, S#{msg := "", sel := none}))}
    end;
%% Tab: the next cell -- contact, coil, a card's field -- and after a
%% line's last its next line's first; shift_tab back.
key1(K, S) when K =:= tab; K =:= shift_tab ->
    Dir = case K of tab -> 1; shift_tab -> -1 end,
    {ok, maps:without([anchor, free], cell(Dir, S#{msg := "", sel := none}))};
key1({click, Ln, open}, S) -> toggle_open(S, Ln);
key1({click, Ln, check}, S) -> key1({dclick, Ln, handle}, S);
%% A rung shown under an object: the module's own, where it is written.
key1({click, {in, _, Ln}, P}, S) -> key1({click, Ln, P}, S);
key1({dclick, {in, _, Ln}, P}, S) -> key1({dclick, Ln, P}, S);
key1({select, {in, _, Ln}, Ps}, S) -> key1({select, Ln, Ps}, S);
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
%% A new line of any statement -- a declaration, #module, ... -- after the
%% cursor's node, written in the status line. Not in patch mode: a node is
%% only given rules.
key1($#, S = #{access := patch}) -> {ok, S#{msg := ?PATCH_ONLY}};
key1($#, S = #{doc := D, ln := Ln}) ->
    At = case Ln of
	     0 -> caned_doc:last_line(D);
	     _ -> element(2, span(S, D, Ln)) + 1
	 end,
    {ok, S#{mode := {stmt, "#", At}, msg := "", sel := none}};
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
key2({dclick, Ln, P}, S) -> {ok, start_edit(S#{ln := Ln, cur := P, sel := none})};
%% A rectangle over a card or a comment: what is in it is no range of
%% contacts, so it is a click on the first.
key2({select, Ln, Ps = [P | _]}, S = #{doc := D}) when is_integer(Ln) ->
    case caned_doc:rung(D, Ln) of
        none -> key1({click, Ln, P}, S);
        _ -> select(Ln, [P0 || P0 <- Ps, is_list(P0) orelse P0 =:= coil], S)
    end;
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
	{ok, D1} -> {ok, declare_new(fix_cur(doc_change(D1, S#{sel := none})))};
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
		     _ -> declare_new(S1#{ln := At, cur := first_leaf(D1, At)})
		 end};
	{error, M} -> {ok, S#{msg := "not pasted: " ++ M}}
    end.

no(D, Ln) ->
    case lists:keyfind(Ln, 1, caned_doc:numbers(D)) of
	{_, N} -> integer_to_list(N);
	false -> "?"
    end.

select(Ln, [], S) -> {ok, S#{ln := Ln}};
select(Ln, Ps, S = #{doc := D}) ->
    R = sel_range(tree(D, Ln), Ps),
    {ok, S#{ln := Ln, cur := hd(Ps), sel := {Ln, R},
            msg := "selected: " ++ copy(D, Ln, R)}}.

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
normal(K, S = #{embedded := true}) when K =:= $q; K =:= $Q -> {ok, S};
normal($s, S = #{embedded := true}) -> {save, S};
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
    Rs = shown_stops(S),
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

%% The keyword is a cell, {seg, 0}, where the declaration can be turned into
%% another kind (caned_menu:kinds/0): the card's first cell then, 1 else.
kw_cell(D, Ln) ->
    case lists:member(element(1, caned_doc:stmt(D, Ln)), caned_menu:kinds()) of
        true -> 0;
        false -> 1
    end.

card_key(K, S = #{doc := D, ln := Ln, cur := {seg, I}}) when K =:= left; K =:= right ->
    N = length(fields(D, Ln)),
    {ok, S#{cur := {seg, max(kw_cell(D, Ln), min(N, I + case K of left -> -1; right -> 1 end))}}};
%% The keyword: its kind chosen from the kinds, written as one of those.
card_key(K, S = #{cur := {seg, 0}}) when K =:= enter; K =:= $e ->
    %% empty: what is typed narrows the kinds, Tab puts one in
    {ok, S#{mode := {field, kw, "", "", 0}, msg := ""}};
card_key(K, S = #{cur := {seg, 0}}) when K =:= $x; K =:= del ->
    {ok, S#{msg := "the kind is changed, not taken off: ⏎"}};
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
field(enter, kw, _, Text, _, S = #{doc := D, ln := Ln}) ->
    T = string:trim(string:trim(Text), leading, "#"),
    case T =:= "" orelse lists:member(T, [atom_to_list(K) || K <- caned_menu:kinds()]) of
        true when T =:= "" -> {ok, S#{mode := normal, msg := ""}};
        true ->
            New = caned_decl:convert(caned_doc:stmt(D, Ln), list_to_atom(T)),
            case caned_doc:set_kind(D, Ln, New) of
                {ok, D1} -> {ok, (doc_change(D1, S))#{mode := normal, msg := ""}};
                {error, M} -> {ok, S#{msg := M}}
            end;
        false -> {ok, S#{msg := "not a kind: " ++ T}}
    end;
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

%% An object's line opened, or closed again; another line is left alone.
toggle_open(S = #{doc := D}, Ln) ->
    case caned_doc:stmt(D, Ln) of
        {object, _, _, {'WORD', _, O}, _} ->
            Open = maps:get(open, S, []),
            {ok, S#{open => case lists:member(O, Open) of
                                true -> Open -- [O];
                                false -> [O | Open]
                            end, msg := ""}};
        _ -> {ok, S}
    end.

%% The lines of module M's rungs, in its body: between its #module and the
%% #end that closes it, not one of a block inside.
module_rungs(D, M) ->
    Ss = caned_doc:stmts(D),
    case lists:dropwhile(fun(St) -> not is_module(St, M) end, Ss) of
        [_Start | Rest] -> body_rungs(D, Rest, 0, []);
        [] -> []
    end.

is_module({module, _, {'WORD', _, M}}, M) -> true;
is_module({module, _, {'WORD', _, M}, _}, M) -> true;
is_module(_, _) -> false.

body_rungs(_D, [{'end', _} | _], 0, Acc) -> Acc;
body_rungs(D, [St | Rest], Depth, Acc) ->
    Depth1 = case element(1, St) of
                 'end' -> Depth - 1;
                 K when K =:= in; K =:= 'when' -> Depth + 1;
                 _ -> Depth
             end,
    Ln = caned_doc:line_of(St),
    Acc1 = case caned_doc:rung(D, Ln) of
               none -> Acc;
               _ -> Acc ++ [Ln]
           end,
    body_rungs(D, Rest, Depth1, Acc1);
body_rungs(_D, [], _, Acc) -> Acc.

%% Under an open object's line: its module's rungs, keyed {in, O, Line}.
inline_rows(S = #{doc := D}, L, Widths, Nos, Cs) ->
    case caned_doc:stmt(D, L) of
        {object, _, {'WORD', _, M}, {'WORD', _, O}, _} ->
            case lists:member(O, maps:get(open, S, [])) of
                true ->
                    S1 = S#{ln := 0, sel := none},
                    lists:append(
                      [[[{{shade, inline, none, bands(S, L)}, ""}, {lineno, "     "}, {text, "    "} |
                         [re_key(Run, O) || Run <- tl(R)]]
                        || R <- line_rows(S1, X, maps:get(X, Widths, {0, 0}), Nos, Cs)]
                       || X <- module_rungs(D, M)]);
                false -> []
            end;
        _ -> []
    end.

re_key({{A, {X, P}}, T}, O) when is_integer(X), P =/= handle -> {{A, {{in, O, X}, P}}, T};
re_key({{A, {_X, handle}}, T}, _O) -> {A, T};
re_key(Run, _O) -> Run.

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

%%% ------------------------------------------------------------- names
%%%
%%% A name the rung just written uses and nothing declares (caned_names) is
%%% declared for it: `#variable N' where its scope's declarations end, its
%%% type as the rung assigns it -- one change with the rung, one undo. One
%%% that may be a declared name mistyped is asked about in the status line:
%%% ⏎ declares it, Tab writes the declared one in its place, Esc leaves it.
%%% Declared so, a name is the document's `auto' -- see removing.

declare_new(S = #{access := patch}) -> S;
declare_new(S = #{doc := D, ln := Ln}) ->
    case caned_names:unknown(D, Ln) of
        [] -> S;
        [N | _] ->
            case caned_names:near(D, N) of
                [] -> declare_new(declare_one(S, N));
                Near -> S#{mode := {declare, N, Near}}
            end
    end.

declare_one(S = #{doc := D, ln := Ln}, N) ->
    {ok, D1, At} = caned_names:declare(D, Ln, N, assigned_type(D, Ln, N)),
    Ln1 = case At =< Ln of true -> Ln + 1; false -> Ln end,
    S#{doc := D1#{auto => [N | maps:get(auto, D1, [])]}, ln := Ln1,
       msg := "declared: " ++ string:trim(caned_doc:line(D1, At))}.

%% What rung Ln gives N: a float, a string, a truth (a width of 1), or
%% nothing to say (none).
assigned_type(D, Ln, N) ->
    {rule, _, As, _} = caned_doc:stmt(D, Ln),
    case [V || {Op, _, {field, _, {'WORD', _, N1}}, V} <- As, N1 =:= N,
               Op =:= '=' orelse Op =:= '<-'] of
        [{'FLT', _, _} | _] -> float;
        [{'STR', _, _} | _] -> string;
        [{Op, _, _, _} | _] when Op =:= '&&'; Op =:= '||'; Op =:= '=='; Op =:= '!=';
                                 Op =:= '<'; Op =:= '>'; Op =:= '<='; Op =:= '>=' -> bit;
        [{'!', _, _} | _] -> bit;
        _ -> none
    end.

declare_key(enter, N, _Near, S) -> {ok, declare_new(declare_one(S#{mode := normal}, N))};
declare_key(tab, N, [K | _], S = #{doc := D, ln := Ln}) ->
    case caned_names:rename(D, Ln, N, K) of
        {ok, D1} -> {ok, declare_new(S#{doc := D1, mode := normal, msg := ""})};
        {error, M} -> {ok, S#{msg := M}}
    end;
declare_key(K, N, Near, S) when K =:= down; K =:= shift_tab; K =:= up ->
    Near1 = case K of
                down -> tl(Near) ++ [hd(Near)];
                _ -> [lists:last(Near) | lists:droplast(Near)]
            end,
    {ok, S#{mode := {declare, N, Near1}}};
declare_key(esc, _N, _Near, S) -> {ok, S#{mode := normal, msg := ""}};
declare_key(_, _N, _Near, S) -> {ok, S}.

stmt_key(esc, _Text, _At, S) -> {ok, S#{mode := normal, msg := ""}};
stmt_key(enter, Text, At, S = #{doc := D, undo := Us}) ->
    %% `none', a place's default, is not written
    Line = string:join([W || W <- string:lexemes(Text, " "), W =/= "none"], " "),
    case caned_doc:insert_line(D, At, Line) of
	{ok, D1} ->
	    {ok, S#{doc := D1, undo := [D | Us], redo := [], ln := At, cur := cur_for(D1, At),
		    mode := normal, msg := ""}};
	{error, M} -> {ok, S#{msg := M}}
    end;
%% Space on a place left empty: its default, the first of its choices; on
%% one with none (the name) nothing -- words are a blank apart.
stmt_key($\s, Text, At, S) ->
    T1 = case lists:suffix(" ", Text) andalso decl_choices(Text, S) of
             {_, "", [Default | _]} -> Text ++ Default ++ " ";
             false -> Text ++ " ";
             _ -> Text                           % no empty words: one blank apart
         end,
    {ok, S#{mode := {stmt, T1, At}, msg := ""}};
stmt_key(K, Text, At, S) when K =:= tab; K =:= shift_tab ->
    {T1, S1} = complete(K, Text, S),
    {ok, S1#{mode := {stmt, T1, At}}};
stmt_key(backspace, "", _At, S) -> {ok, S};
stmt_key(backspace, Text, At, S) -> {ok, S#{mode := {stmt, lists:droplast(Text), At}}};
stmt_key(C, Text, At, S) when is_integer(C), C >= $\s ->
    {ok, S#{mode := {stmt, Text ++ [C], At}, msg := ""}};
stmt_key(_, _Text, _At, S) -> {ok, S}.

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
    %% a hole is written over, not after
    S#{mode := {edit_coil, case caned_doc:coil_text(D, Ln) of "_" -> ""; T -> T end}};
start_edit(S = #{doc := D, ln := Ln, cur := P}) ->
    Text = case caned_tree:get(tree(D, Ln), P) of
	       {leaf, {hole, _}} -> "";
	       N -> caned_tree:text(N)
	   end,
    S#{mode := {edit, Text}}.

edit_coil(esc, _Text, S) -> {ok, S#{mode := normal, msg := ""}};
edit_coil(enter, Text, S = #{doc := D, ln := Ln}) ->
    case caned_doc:set_coil(D, Ln, string:trim(Text)) of
	{ok, D1} -> {ok, declare_new((doc_change(D1, S))#{mode := normal})};
	{error, M} -> {ok, S#{msg := M}}
    end;
edit_coil(backspace, "", S) -> {ok, S};
edit_coil(backspace, Text, S) -> {ok, S#{mode := {edit_coil, lists:droplast(Text)}}};
edit_coil(C, Text, S) when is_integer(C), C >= $\s ->
    {ok, S#{mode := {edit_coil, Text ++ [C]}, msg := ""}};
edit_coil(K, Text, S) when K =:= tab; K =:= shift_tab ->
    {T1, S1} = complete(K, Text, S),
    {ok, S1#{mode := {edit_coil, T1}}};
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
	    {ok, declare_new(maps:remove(added, S1#{mode := normal}))};
	{error, M} -> {ok, S#{msg := M}}
    end;
edit(K, Text, S) when K =:= tab; K =:= shift_tab ->
    {T1, S1} = complete(K, Text, S),
    {ok, S1#{mode := {edit, T1}}};
edit(backspace, "", S) -> {ok, S};
edit(backspace, Text, S) -> {ok, S#{mode := {edit, lists:droplast(Text)}}};
edit(C, Text, S) when is_integer(C), C >= $\s ->
    {ok, S#{mode := {edit, Text ++ [C]}, msg := ""}};
edit(_, _Text, S) -> {ok, S}.

%% Tab (shift_tab back) on what is written, as a shell completes: the
%% first choice what was typed begins, then round the ones it begins; the
%% state's `cycle' {Base, Typed, Choice} keeps what was typed while Tab
%% goes round. Nothing offered, or nothing fits what was typed: the text as
%% it was -- Tab never writes over what was typed. {Text, S}.
complete(K, Text, S) ->
    Dir = case K of tab -> 1; shift_tab -> -1 end,
    case {maps:get(cycle, S, none), choices_at(Text, S)} of
        {{Base, Typed, Cur}, {Base, Cur, Ps}} ->
            Fit = fits(Typed, Ps),
            I = index_in(Fit, Cur),
            Next = lists:nth((I - 1 + Dir + length(Fit)) rem length(Fit) + 1, Fit),
            {Base ++ Next, S#{cycle => {Base, Typed, Next}}};
        {_, {Base, Part, Ps}} ->
            case fits(Part, Ps) of
                [] -> {Text, S};
                Fit ->
                    First = case Dir of 1 -> hd(Fit); -1 -> lists:last(Fit) end,
                    {Base ++ First, S#{cycle => {Base, Part, First}}}
            end;
        _ -> {Text, S}
    end.

fits(Typed, Ps) -> [P || P <- Ps, lists:prefix(Typed, P)].

%% What may be written at the end of Text: a name's parts after `Name.';
%% a value after `X =', `X ==', `X !=' or `X <-' (caned_names:values/3 --
%% State's states, a family of defines). {the text before it, what is
%% written of it so far, the choices} | none.
choices_at(Text, S = #{mode := {stmt, _, _}}) -> decl_choices(Text, S);
choices_at(Text, S) ->
    case parts_at(Text, S) of
        none -> values_at(Text, S);
        P -> P
    end.

values_at(Text, #{doc := D, ln := Ln}) ->
    case re:run(Text, "([A-Za-z][A-Za-z0-9_.]*)\\s*(==|!=|<-|(?<![<>!=])=)\\s*([A-Za-z0-9_]*)$",
                [{capture, all, list}]) of
        {match, [_, X, _, Part]} ->
            case caned_names:values(D, Ln, X) of
                [] -> none;
                Vs -> {lists:sublist(Text, length(Text) - length(Part)), Part, Vs}
            end;
        nomatch -> none
    end.

%% The guided card (#): the word being written of a new line. The first is
%% what the line is (caned_menu:heads/1), the second its name, written
%% freely; then the options of the groups the kind has and that are not
%% taken yet, in the groups' order. {Base, Part, Choices} | none.
decl_choices(Text, #{doc := D}) ->
    case string:split(Text, " ", all) of
        ["#" ++ Part] -> {"#", Part, caned_menu:heads(D)};
        [_, _Name] -> none;
        ["#" ++ Head | Rest] when length(Rest) >= 2 ->
            Part = lists:last(Rest),
            Kind = kind_of_head(Head),
            case slot(Kind, length(Rest) - 1) of
                {_, []} -> none;
                {_, Cs} -> {lists:sublist(Text, length(Text) - length(Part)), Part, Cs};
                past -> none;
                groups -> group_choices(Text, Kind, Rest, Part)
            end;
        _ -> none
    end.

%% The words of the groups a kind has and that are not taken yet.
group_choices(Text, Kind, Rest, Part) ->
    Taken = [caned_menu:group(W) || W <- lists:droplast(tl(Rest))],
    case [W || G <- caned_menu:groups_of(Kind), not lists:member(G, Taken),
               W <- caned_menu:words(G)] of
        [] -> none;
        Ws -> {lists:sublist(Text, length(Text) - length(Part)), Part, Ws}
    end.

%% A #digital's and an #analog's places after the name, in order: {Label,
%% Choices} for the Ith ([] free: the pin), past after the last -- what
%% else goes on one (invert, a trigger, ...) the card's + puts on after.
%% none, first, is the default and is not written. groups: the kind is
%% written a group at a time instead.
slot(digital, I) -> nth_slot(I, [{"dir", ["in", "out", "inout"]},
                                 {"pull", ["none", "pullup", "pulldown"]}, {"pin", []}]);
slot(analog, I) -> nth_slot(I, [{"dir", ["in", "out", "inout"]},
                                {"pwm", ["none", "pwm"]}, {"pin", []}]);
slot(_, _) -> groups.

nth_slot(I, Slots) when I =< length(Slots) -> lists:nth(I, Slots);
nth_slot(_, _) -> past.

%% The kind a guided card's first word names, none for one that is no
%% declaration's (an object's module, #states, ...).
kind_of_head(Head) ->
    case [K || K <- caned_menu:kinds() ++ [buffer, field], atom_to_list(K) =:= Head] of
        [K] -> K;
        [] -> none
    end.

%% The guided card's status: what is written, and after it what the word
%% being written can be -- the kinds, or the option groups left, each by
%% its name, those the word begins, the one Tab puts in lit.
decl_offered(Text, S = #{doc := _}) ->
    case string:split(Text, " ", all) of
        ["#" ++ Head | Rest] when length(Rest) >= 2 ->
            Kind = kind_of_head(Head),
            I = length(Rest) - 1,
            case slot(Kind, I) of
                groups -> group_offered(Text, S, Kind, Rest);
                past -> [{help, "   ⏎ -- + on the card adds the rest"}];
                {Label, Cs} ->
                    Part = lists:last(Rest),
                    Lit = lit_choice(Text, S),
                    Then = [L || J <- lists:seq(I + 1, 3), {L, _} <- [slot(Kind, J)]],
                    [{help, "   " ++ Label ++ ":"}] ++
                        [{case C of Lit -> menu_sel; _ -> menu end, " " ++ C}
                         || C <- Cs, lists:prefix(Part, C)] ++
                        [{help, "   then " ++ string:join(Then, ", ")} || Then =/= []]
            end;
        [_, _] -> [{help, "   the name"}];
        _ -> offered(Text, S)
    end.

group_offered(Text, S, Kind, Rest) ->
    Taken = [caned_menu:group(W) || W <- lists:droplast(tl(Rest))],
    Part = lists:last(Rest),
    Lit = lit_choice(Text, S),
    lists:append(
      [[{help, "   " ++ atom_to_list(G) ++ ":"} |
        [{case W of Lit -> menu_sel; _ -> menu end, " " ++ W} || W <- Fit]]
       || G <- caned_menu:groups_of(Kind), not lists:member(G, Taken),
          Fit <- [[W || W <- caned_menu:words(G), lists:prefix(Part, W)]], Fit =/= []]).

%% The choice lit: the one Tab put in, going round; else the first fitting.
lit_choice(Text, S) ->
    case {maps:get(cycle, S, none), choices_at(Text, S)} of
        {{Base, _, Cur}, {Base, Cur, _}} -> Cur;
        {_, {_, Part, Ps}} -> case fits(Part, Ps) of [F | _] -> F; [] -> none end;
        _ -> none
    end.

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

%% How many rows the whole document takes on a screen.
height(S) ->
    {Body, _} = body(S),
    length(Body).

%% Rows by Cols: the file from the top line, the status line last. The view
%% scrolls to keep the cursor's rung in it.
screen(S0, Rows, Cols) ->
    S = scroll(S0#{page => Rows - 2}, Rows - 1),
    {Body, _} = body(S),
    #{top := Top} = S,
    View = light(lists:sublist(lists:nthtail(min(Top - 1, length(Body)), Body), Rows - 1), S),
    Pad = lists:duplicate(Rows - 1 - length(View), [{blank, ""}]),
    {S, [clip(R, Cols) || R <- View ++ Pad] ++ [clip(status(S), Cols)]}.

%% The whole document's rows, unlit, the status line last: for a host that
%% scrolls them itself (candid's canvas) and lights them as often as what
%% holds changes (light/2) -- the layout only when the editor's state does.
all(S) ->
    {Body, _} = body(S),
    Body ++ [status(S)].

%% Rows lit by the state's `lights' (see LIGHTS above); as they are without.
light(Rows, #{lights := Lt} = S) ->
    {Lit, _} = lists:mapfoldl(fun(R, M) -> light_row(R, M, Lt, S) end, #{}, Rows),
    Lit;
light(Rows, _S) -> Rows.

%% M memoises a line's tree and whether its rung's block is in force.
light_row(Runs, M0, Lt, S) ->
    lists:mapfoldl(
      fun({{A, {L, P}}, T}, M) when A =:= contact; A =:= coil ->
              {{Tr, Dark}, M1} = line_info(L, M, Lt, S),
              Light = case P of
                          coil -> Lt(L, coil);
                          _ -> Lt(L, {contact, caned_tree:expr(caned_tree:get(Tr, P))})
                      end,
              A1 = lit(A, Light),
              {{{case Dark of true -> dim(A1); false -> A1 end, {L, P}}, T}, M1};
         ({{A, {L, P}}, T}, M) when (is_integer(L) orelse element(1, L) =:= in),
                                    A =/= lineno, A =/= lineno_off ->
              {{_, Dark}, M1} = line_info(L, M, Lt, S),
              {{{case Dark of true -> dim(A); false -> A end, {L, P}}, T}, M1};
         (Run, M) -> {Run, M}
      end, M0, Runs).

line_info(L, M, Lt, S) ->
    case maps:find(L, M) of
        {ok, I} -> {I, M};
        error ->
            Real = case L of {in, _, X} -> X; _ -> L end,
            I = {case caned_doc:rung(maps:get(doc, S), Real) of
                     none -> none;
                     _ -> shown(S, Real)
                 end, Lt(L, row) =:= off},
            {I, M#{L => I}}
    end.

%% The screen as plain text: what a test compares.
plain(S, Rows, Cols) ->
    {_, Rs} = screen(S, Rows, Cols),
    [string:trim(lists:append([T || {_, T} <- R]), trailing) || R <- Rs].

%% Every line's rows, and the row each line starts on.
body(S0 = #{doc := D}) ->
    S = S0#{levels => levels(D)},
    N = caned_doc:nlines(D),
    {L0, L1} = lines(S),
    Widths = widths(S, rungs(D)),
    Nos = maps:from_list(caned_doc:numbers(D)),
    Cs = maps:from_list([{X, {F, L}} || {F, L, _, _} <- caned_doc:comments(D),
					X <- lists:seq(F, L)]),
    {RevRows, Starts, Count} =
	lists:foldl(
	  fun(L, {Acc, St, K}) ->
		  Rs = case note_rows(S, L) of
			   none -> line_rows(S, L, maps:get(L, Widths, {0, 0}), Nos, Cs);
			   Ns -> Ns
		       end,
		  B = shade(S, L, Cs),
		  In = inline_rows(S, L, Widths, Nos, Cs),
		  {lists:reverse(In, lists:reverse([[B | R] || R <- Rs], Acc)), St#{L => K + 1},
		   K + length(Rs) + length(In)}
	  end, {[], #{}, 0}, lists:seq(L0, L1)),
    Rows = lists:reverse(RevRows),
    case L1 =:= N andalso note_rows(S, N + 1) of
	false -> {Rows, Starts};
	none -> {Rows, Starts};
	More -> {Rows ++ [[shade(S, N + 1, Cs) | R] || R <- More],
		 Starts#{N + 1 => Count + 1}}
    end.

%% The coils lined up and the right rail with them, a GROUP at a time: rungs
%% on lines that follow each other. A block's head, a comment or a
%% declaration between them starts another, so one wide rung does not push
%% every coil in the file out of sight. #{Line => {Width, CoilW}}.
widths(S = #{doc := D}, Rungs) ->
    Groups = lists:foldr(fun(L, [[L1 | G] | Gs]) when L1 =:= L + 1 -> [[L, L1 | G] | Gs];
                            (L, Gs) -> [[L] | Gs]
                         end, [], Rungs),
    maps:from_list(
      lists:append(
        [begin
             W = lists:max([0 | [X || L <- G, {X, _, _, _} <- [caned_grid:el(shown(S, L), none)]]]),
             C = lists:max([0 | [length(caned_doc:coil_text(D, L)) || L <- G]]),
             [{L, {W, C}} || L <- G]
         end || G <- Groups])).

%% The shade a line's rows lie on: what kind of line it is -- rung, card
%% (a declaration), comment, text -- and whether the cursor's node is it,
%% focused (the keys go here) or idle (they go elsewhere). Drawn as a shade
%% behind the line and a frame round the cursor's node; nothing in a
%% terminal.
shade(S = #{doc := D, ln := Cur}, L, Cs) ->
    Being = case maps:get(mode, S) of
		{note, _, _, {at, F0}} -> F0;
		{note, _, _, {new, At}} -> At;
		_ -> none
	    end,
    {Kind, Node} = case maps:find(L, Cs) of
		       {ok, {F, _}} -> {comment, F};
		       error when L =:= Being -> {comment, L};
		       error ->
			   case {caned_doc:rung(D, L), caned_doc:stmt(D, L)} of
			       {none, none} -> {text, none};
			       {none, _} -> {card, L};
			       _ -> {rung, L}
			   end
		   end,
    Focus = case Node =:= Cur orelse (Being =/= none andalso Node =:= Being) of
		true when Cur > 0 -> case maps:get(focused, S, true) of
					 true -> cur;
					 false -> idle
				     end;
		_ -> none
	    end,
    {{shade, Kind, Focus, bands(S, L)}, ""}.

%% LEVELS: how deep in #module, #in and #when a line is, {Depth, Role},
%% Role open | 'else' | close (the block's own lines, at the depth of the
%% line that opens it) | body. A line is shown that deep, two characters a
%% level, whatever its own white space is -- tabs and spaces mixed are no
%% indentation to go by.
levels(D) ->
    {Ls, _} = lists:mapfoldl(
		fun(L, Dp) ->
			case caned_doc:stmt(D, L) of
			    none -> {{L, {Dp, body}}, Dp};
			    St ->
				case element(1, St) of
				    K when K =:= module; K =:= in; K =:= 'when' ->
					{{L, {Dp, open}}, Dp + 1};
				    'else' -> {{L, {max(0, Dp - 1), 'else'}}, Dp};
				    'end' -> {{L, {max(0, Dp - 1), close}}, max(0, Dp - 1)};
				    _ -> {{L, {Dp, body}}, Dp}
				end
			end
		end, 0, lists:seq(1, caned_doc:nlines(D))),
    maps:from_list(Ls).

%% A line's indentation, by its level; its own white space where there are
%% no levels (a line shown by itself).
ind(S, L, Own) ->
    case maps:find(L, maps:get(levels, S, #{})) of
	{ok, {Dp, _}} -> lists:duplicate(2 * Dp, $\s);
	error -> Own
    end.

%% The band a line's rows lie in: {Levels, Role} -- the block's own lines in
%% the block's band, its body as deep as it is.
bands(S, L) ->
    case maps:find(L, maps:get(levels, S, #{})) of
	{ok, {Dp, body}} -> {Dp, body};
	{ok, {Dp, R}} -> {Dp + 1, R};
	error -> {0, body}
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
%% The guided card being written, in its place: a line of its own above
%% line At, what is written so far.
note_rows(S = #{mode := {stmt, Text, At}, doc := D}, L) when L =:= At ->
    Ls = maps:get(lines, D),
    Ref = case L > 1 andalso L - 1 =< length(Ls) of
              true -> lists:nth(L - 1, Ls);
              false -> ""
          end,
    Indent = lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, Ref),
    [[{lineno, "     "}, {text, Indent}, {field_edit, Text ++ "▏"}]] ++
        case L > length(Ls) of
            true -> [];
            false -> line_rows(S#{mode := normal}, L)
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
    Cs = maps:from_list([{X, {F, La}} || {F, La, _, _} <- caned_doc:comments(D),
					 X <- lists:seq(F, La)]),
    line_rows(S, L, maps:get(L, widths(S, rungs(D)), {0, 0}),
	      maps:from_list(caned_doc:numbers(D)), Cs).

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
	    Own = indent(lists:nth(F, maps:get(lines, D))),
	    W = box_width(Own, Ts),
	    Box = box(ind(S, F, Own), W, Frame, comment, {F, comment}),
	    [Box(top) || L =:= F] ++ [Box({text, lists:nth(L - F + 1, Ts)})] ++
		[Box(bottom) || L =:= La];
	none ->
	    case caned_doc:stmt(D, L) of
		none ->
		    Txt = caned_doc:line(D, L),
		    [[{NoA, No}, {text, ind(S, L, indent(Txt)) ++ string:trim(Txt, leading)}]];
		St -> [[{NoA, No} | card_row(S, L, St)]]
	    end;
	{_, _} ->
	    P = case L of Cur -> maps:get(cur, S); _ -> none end,
	    Sel = case maps:get(sel, S) of {L, R} -> R; _ -> none end,
	    E = caned_grid:rung(shown(S, L), caned_doc:coil_text(D, L), P, Sel, Width, CoilW),
	    %% A contact's cells say which rung they are on as well, for a click;
	    %% an off rule's are dim.
	    %% Lit afterwards (light/2): the layout does not change when only
	    %% what holds does.
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
	    Ind = {text, ind(S, L, "")},
	    [[{{NoA, {L, handle}}, No}, Ind | Row1] ++ Trail | [[{lineno, "     "}, Ind | R] || R <- More]]
    end.

%% A declaration as its card: the keyword, each field on its own; the one
%% being written as it is so far.
card_row(S = #{doc := D, ln := Cur, mode := Mode}, L, St) ->
    [{kw, Kw} | _] = [{kw, T} || {kw, _, T} <- caned_decl:segs(St)],
    Fs = tl(caned_decl:segs(St)),
    Line = caned_doc:line(D, L),
    Indent = ind(S, L, indent(Line)),
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
    Opener = case St of
                 {object, _, _, {'WORD', _, O}, _} ->
                     [{{opener, {L, open}},
                       case lists:member(O, maps:get(open, S, [])) of
                           true -> "▾ ";
                           false -> "▸ "
                       end}];
                 _ -> []
             end,
    KwCell = case {kw_cell(D, L), Edit} of
                 {1, _} -> {kw, Kw};
                 {0, {kw, Te}} -> {{field_edit, {L, {seg, 0}}}, "#" ++ Te ++ "▏"};
                 {0, _} when CI =:= 0 -> {{field_cur, {L, {seg, 0}}}, Kw};
                 {0, _} -> {{kw, {L, {seg, 0}}}, Kw}
             end,
    [{text, Indent} | Opener] ++ [KwCell] ++
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

%% A contact or coil as it is lit; the cursor's and a selection keep their
%% own look.
lit(contact, true) -> contact_t;
lit(contact, unknown) -> contact_u;
lit(coil, fired) -> coil_on;
lit(coil, both) -> coil_on;
lit(coil, next) -> coil_nx;
lit(A, _) -> A.

dim(contact) -> off;
dim(contact_t) -> off;
dim(contact_u) -> off;
dim(coil_on) -> coil_off;
dim(coil_nx) -> coil_off;
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
    First = maps:get(Ln, Starts, 1),
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
    [{status, " new rung, its coil (B, or B = 1): "}, {edit, Text ++ "▏"}] ++
	[{error, "   " ++ M} || M =/= ""];
status(#{mode := {declare, N, [K | Ks]}}) ->
    [{status, " " ++ N ++ " is not declared: "}, {help, "⏎ declares it   Tab "},
     {menu_sel, " " ++ K ++ " "}] ++ [{menu, " " ++ X ++ " "} || X <- Ks] ++
        [{help, "   Esc leaves it"}];
status(S = #{mode := {stmt, Text, _}, msg := ""}) ->
    [{status, " new line: "}, {edit, Text ++ "▏"}] ++ decl_offered(Text, S);
status(#{mode := {stmt, Text, _}, msg := M}) ->
    [{status, " new line: "}, {edit, Text ++ "▏"}] ++ [{error, "   " ++ M} || M =/= ""];
status(S = #{mode := {edit_coil, Text}, msg := ""}) ->
    [{status, " coil: "}, {edit, Text ++ "▏"}] ++ offered(Text, S);
status(#{mode := {edit_coil, Text}, msg := M}) ->
    [{status, " coil: "}, {edit, Text ++ "▏"}] ++ [{error, "   " ++ M} || M =/= ""];
status(#{mode := {note, _, _, _}}) ->
    [{status, " comment: "}, {help, "⇧⏎ or ^J a new line   ⏎ done   Esc leave it as it was"}];
status(S = #{mode := {field, Key, Typed, Text, _}, msg := M}) ->
    Name = case Key of
               add -> "add";
               kw -> "kind";
               {opt, _} -> "option";
               _ -> atom_to_list(Key)
           end,
    [{status, " " ++ Name ++ ": "}, {edit, Text ++ "▏"}, {help, "  "}] ++
        [{case C of Text -> menu_sel; _ -> menu end, " " ++ C ++ " "}
         || C <- choices(Key, Typed, S)] ++
        [{error, "   " ++ M} || M =/= ""];
status(S = #{mode := {edit, Text}, msg := M}) when M =:= "" ->
    [{status, " write: "}, {edit, Text ++ "▏"}] ++ offered(Text, S);
status(#{mode := {edit, Text}, msg := M}) ->
    [{status, " write: "}, {edit, Text ++ "▏"}] ++
	[{error, "   " ++ M} || M =/= ""];
%% Embedded (candid): no name and no help -- the host has its file menu --
%% only what is said, when something is.
status(#{embedded := true, msg := M}) -> [{msg, M} || M =/= ""];
status(#{file := F, doc := D, msg := M, access := A}) ->
    Dirty = case caned_doc:dirty(D) of true -> " *"; false -> "" end,
    [{status, " " ++ filename:basename(F) ++ Dirty ++ " [" ++ atom_to_list(A) ++ "]  "}] ++
	case M of
	    "" -> [{help, ?HELP}];
	    _ -> [{msg, M}]
	end.

%% What Tab offers where the text ends, quietly after it on the status
%% line: the choices what was typed begins, lit the one Tab puts in (or
%% has put in, going round); none when nothing is offered or nothing fits
%% -- typing goes on as it was.
offered(Text, S) ->
    {Typed, Lit} = case {maps:get(cycle, S, none), choices_at(Text, S)} of
                       {{Base, T, Cur}, {Base, Cur, Ps0}} -> {T, {Cur, Ps0}};
                       {_, {_, Part, Ps0}} -> {Part, {first, Ps0}};
                       _ -> {"", none}
                   end,
    case Lit of
        none -> [];
        {Sel, Ps} ->
            case fits(Typed, Ps) of
                [] -> [];
                Fit = [F | _] ->
                    On = case Sel of first -> F; _ -> Sel end,
                    [{help, "   Tab:"} |
                     [{case P of On -> menu_sel; _ -> menu end, " " ++ P} || P <- Fit]]
            end
    end.

%% No wider than the screen.
clip(Runs, Cols) -> clip(Runs, Cols, []).

clip([], _, Acc) -> lists:reverse(Acc);
clip(_, 0, Acc) -> lists:reverse(Acc);
clip([{A, T} | R], N, Acc) when length(T) =< N -> clip(R, N - length(T), [{A, T} | Acc]);
clip([{A, T} | _], N, Acc) -> lists:reverse([{A, lists:sublist(T, N)} | Acc]).
