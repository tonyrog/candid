%%% caned's document: a candyspeak file as its LINES and the statement on
%%% each. One statement is one line (the grammar ends every one at 'end of
%%% line'), so a statement is known by its line number, and saving writes
%%% back the file as it was with only the changed statements printed anew --
%%% comments, blank lines and layout elsewhere byte for byte. A changed line
%%% keeps its indentation and a `// comment' after it.
%%%
%%% Only whole files that parse are taken; a repair mode is for later.
%%%
%%% A RUNG is what the ladder edits on a rule's line: the guard of a guarded
%%% rule, or the condition of an unguarded `X = <condition>' with X its coil
%%% (as csp_code draws it). `X = _' -- a hole -- is a rung too: a new one.
%%% A rule with no guard and no condition, `Red = 0, Yellow = 0', is a rung
%%% whose condition is always (caned_tree): a wire straight to its coil.
%%%
%%% A rule's NUMBER is csp's (csp_code:rules/2, what /list shows and #disable
%%% takes), not its line. The `#disable'/`#enable' lines of a file are taken
%%% off when it is read and are marks on the lines they name (off): a rule
%%% that moves takes its mark with it. Saving writes them back as one
%%% `#disable' line at the end, by the numbers the rules have then. A line
%%% put in since the file was read is marked added.
%%%
%%% A COMMENT is a block of lines that are a comment and nothing else: `//'
%%% lines (blanks before them allowed), or `#annotate caned comment "..."'
%%% lines, which mean the same and are in the parsed program for tools that
%%% read it. A `//' after a statement is no part of it: while the line is as
%%% it was it stays there, byte for byte; printed anew, the statement goes on
%%% a line of its own and the comment on `//' lines above it. A comment written
%%% anew keeps its form; `//' lines are broken at ?WIDTH columns, the
%%% indentation and the `// ' counted -- a line is only broken, never joined
%%% with the next, so what was laid out by hand stays so. An #annotate line
%%% is one line of the comment, never broken.

-module(caned_doc).

%% `X = <condition>': X is the coil. A hole is a condition not written yet.
-define(IS_COND(X),
	(element(1, X) =:= hole orelse element(1, X) =:= '!' orelse
	 (tuple_size(X) =:= 4 andalso
	  (element(1, X) =:= '&&' orelse element(1, X) =:= '||' orelse
	   element(1, X) =:= '==' orelse element(1, X) =:= '!=' orelse
	   element(1, X) =:= '<' orelse element(1, X) =:= '<=' orelse
	   element(1, X) =:= '>' orelse element(1, X) =:= '>=')))).

-export([load/1, from_text/1, from_text/2, text/1, save/2]).
-export([stmts/1, stmt/2, rung/2, set_rung/3, print_rule/1, line_of/1]).
-export([nlines/1, line/2, dirty/1]).
-export([new_rung/3, delete_line/2, last_line/1]).
-export([coil_text/2, set_coil/3, set_stmt/3, set_decl/3]).
-export([numbers/1, off/2, set_off/3, added/2, move_line/3, insert_stmt/3]).
-export([saved_line/2, saved/1]).
-export([comments/1, comment_at/2, set_comment/3, new_comment/3, delete_lines/3,
         trailing/2, wrap/3, wrap_text/3, text_width/2]).

-define(WIDTH, 80).

%% {ok, Doc} | {error, {Line, Message}}.
load(File) ->
    case file:read_file(File) of
	{ok, Bin} -> from_text(unicode:characters_to_list(Bin), File);
	{error, Why} -> {error, {0, file:format_error(Why)}}
    end.

from_text(Text) -> from_text(Text, "untitled.csp").

%% The file at File (where its #imports are found from).
from_text(Text0, File) ->
    {Lines, Offs} = marks(string:split(Text0, "\n", all)),
    Text = lists:flatten(lists:join("\n", Lines)),
    case parse(Text) of
	{ok, Ast} ->
	    D = #{lines => Lines, file => File,
		  stmts => maps:from_list([{line_of(S), S} || S <- Ast]),
		  dirty => #{}, off => #{}, added => #{}, off_else => []},
	    case Offs of
		[] -> {ok, D};
		_ ->
		    Nos = numbers(D),
		    {ok, D#{off := maps:from_list([{Ln, true} || {Ln, N} <- Nos,
								 lists:member(N, Offs)]),
			    off_else := Offs -- [N || {_, N} <- Nos]}}
	    end;
	E -> E
    end.

%% The `#disable' and `#enable' lines out, and the rules they leave off: a
%% later #enable undoes an earlier #disable.
marks(Ls) -> marks(Ls, [], []).

marks([L | Ls], Acc, Offs) ->
    case string:lexemes(L, " \t") of
	["#disable" | Ns] -> marks(Ls, Acc, lists:usort(Offs ++ nos(Ns)));
	["#enable" | Ns] -> marks(Ls, Acc, Offs -- nos(Ns));
	_ -> marks(Ls, [L | Acc], Offs)
    end;
marks([], Acc, Offs) -> {lists:reverse(Acc), Offs}.

nos(Ns) ->
    lists:append([case string:split(N, "-") of
		      [A, B] -> lists:seq(list_to_integer(A), list_to_integer(B));
		      [A] -> [list_to_integer(A)]
		  end || N <- lists:takewhile(fun(N) -> not lists:prefix("//", N) end, Ns)]).

%%% --------------------------------------------------------------- numbers

%% [{Line, RuleNo}] for the rules on this file's lines, as csp numbers them:
%% the rules of an #import count. An object line has several; a line's
%% number is its first. The last answer is kept, the screen asks often.
numbers(D = #{file := File}) ->
    Src = source(D),
    case get(caned_numbers) of
	{File, Src, Nos} -> Nos;
	_ ->
	    Nos = numbers(Src, File),
	    put(caned_numbers, {File, Src, Nos}),
	    Nos
    end.

numbers(Src, File) ->
    Top = filename:absname(File),
    Base = filename:basename(Top),
    case quiet(fun() -> candyspeak:parse_text(Src ++ "\n", Top, [sources]) end) of
	{ok, Ast} ->
	    first([{Ln, No} || #{no := No, line := Ln, file := F} <- csp_code:rules(Ast, Top),
			       F =:= Base]);
	_ ->                                    % an #import not found: this file's own
	    {ok, Ast} = parse(Src),
	    first([{Ln, No} || #{no := No, line := Ln} <- csp_code:rules(Ast)])
    end.

first(Nos) -> first(Nos, #{}).

first([{Ln, _} | T], Seen) when is_map_key(Ln, Seen) -> first(T, Seen);
first([{Ln, N} | T], Seen) -> [{Ln, N} | first(T, Seen#{Ln => true})];
first([], _) -> [].

%% The parser says what it cannot read on standard output.
quiet(Fun) ->
    {ok, Null} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Null, self()),
    try Fun()
    catch _:_ -> error
    after group_leader(Old, self()), file:close(Null)
    end.

%% Whether the rule on Ln is off; switched.
off(#{off := Off}, Ln) -> maps:is_key(Ln, Off).

set_off(D = #{off := Off}, Ln, true) -> D#{off := Off#{Ln => true}, dirty := dirty_lines(D)};
set_off(D = #{off := Off}, Ln, false) -> D#{off := maps:remove(Ln, Off), dirty := dirty_lines(D)}.

dirty_lines(#{dirty := Dy}) -> Dy#{'$lines' => true}.

added(#{added := A}, Ln) -> maps:is_key(Ln, A).

parse(Text) ->
    T = case lists:suffix("\n", Text) of
	    true -> Text;
	    false -> Text ++ "\n"
	end,
    case candyspeak_scan:string(T) of
	{ok, Toks, _} ->
	    case candyspeak_parse:parse(Toks) of
		{ok, Ast} -> {ok, Ast};
		{error, {L, M, D}} -> {error, {L, lists:flatten(M:format_error(D))}}
	    end;
	{error, {L, M, D}, _} -> {error, {L, lists:flatten(M:format_error(D))}}
    end.

%% The line a statement is on.
line_of(S) when is_integer(element(2, S)) -> element(2, S);
line_of({immediate, E}) -> line_of(E);
line_of(S) -> line_of(element(2, S)).

stmts(#{stmts := Ss}) -> [S || {_, S} <- lists:keysort(1, maps:to_list(Ss))].

stmt(#{stmts := Ss}, Ln) -> maps:get(Ln, Ss, none).

%%% ----------------------------------------------------------------- rungs

%% {Coil, Tree} on rule line Ln: Coil the target of an unguarded condition or
%% none (a guard, the assignments its coil); none if Ln is no rung.
rung(D, Ln) ->
    case stmt(D, Ln) of
	{rule, _, [{'=', _, Tgt, X}], undefined} = R when ?IS_COND(X) ->
	    case printable(R) of
		true  -> {Tgt, caned_tree:tree(X)};
		false -> none
	    end;
	{rule, _, _, undefined} = R ->
	    case printable(R) of
		true  -> {none, {leaf, always}};
		false -> none
	    end;
	{rule, _, _, G} = R when G =/= undefined ->
	    case printable(R) of
		true  -> {none, caned_tree:tree(G)};
		false -> none
	    end;
	_ -> none
    end.

%% The rung on Ln is Tree now: the statement changes, its line is dirty.
set_rung(D = #{stmts := Ss, dirty := Dy}, Ln, Tree) ->
    G = case Tree of
	    {leaf, always} -> undefined;
	    _ -> caned_tree:expr(Tree)
	end,
    S1 = case stmt(D, Ln) of
	     {rule, L, [{'=', L1, Tgt, X}], undefined} when ?IS_COND(X), G =/= undefined ->
		 {rule, L, [{'=', L1, Tgt, G}], undefined};
	     {rule, L, As, _} ->
		 {rule, L, As, G}
	 end,
    D#{stmts := Ss#{Ln => S1}, dirty := Dy#{Ln => true}}.

%% The coil as it is written: the target of `X = <condition>', else the
%% assignments.
coil_text(D, Ln) ->
    case {rung(D, Ln), stmt(D, Ln)} of
	{{none, _}, {rule, _, As, _}} ->
	    lists:flatten(lists:join(", ", [csp_code:assign(A) || A <- As]));
	{{Tgt, _}, _} -> candyspeak_eval:text(Tgt)
    end.

%% The coil written anew: a target for `X = <condition>', assignments for
%% the rest. {ok, Doc} | {error, Message}.
set_coil(D = #{stmts := Ss, dirty := Dy}, Ln, Text) ->
    case {rung(D, Ln), stmt(D, Ln)} of
	{{none, _}, {rule, L, _, G}} ->
	    case parse(Text ++ "\n") of
		{ok, [{rule, _, As, undefined}]} ->
		    {ok, D#{stmts := Ss#{Ln => {rule, L, As, G}}, dirty := Dy#{Ln => true}}};
		{ok, _} -> {error, "not assignments: " ++ Text};
		{error, {_, M}} -> {error, M}
	    end;
	{{_, _}, {rule, L, [{'=', L1, _, X}], undefined}} ->
	    case parse(Text ++ " = _\n") of
		{ok, [{rule, _, [{'=', _, Tgt = {field, _, _}, {hole, _}}], undefined}]} ->
		    {ok, D#{stmts := Ss#{Ln => {rule, L, [{'=', L1, Tgt, X}], undefined}},
			    dirty := Dy#{Ln => true}}};
		_ -> {error, "not a name a rule can write: " ++ Text}
	    end
    end.

%% Line Ln a whole rule anew, from its text (a paste over a selected rung).
set_stmt(D = #{stmts := Ss, dirty := Dy}, Ln, Text) ->
    case parse(Text ++ "\n") of
	{ok, [R = {rule, _, _, _}]} ->
	    {ok, D#{stmts := Ss#{Ln => R}, dirty := Dy#{Ln => true}}};
	{ok, _} -> {error, "not one rule: " ++ Text};
	{error, {_, M}} -> {error, M}
    end.


%% Line Ln's declaration anew from its text: the same kind of statement, no
%% rule. {ok, Doc} | {error, Message}.
set_decl(D = #{stmts := Ss, dirty := Dy}, Ln, Text) ->
    Old = stmt(D, Ln),
    case parse(Text ++ "\n") of
        {ok, [S]} when element(1, S) =:= element(1, Old) ->
            {ok, D#{stmts := Ss#{Ln => S}, dirty := Dy#{Ln => true}}};
        {ok, _} -> {error, "not one " ++ atom_to_list(element(1, Old)) ++ ": " ++ Text};
        {error, {_, M}} -> {error, M}
    end.

%% A rule caned can print back: not a pack or an unpack (csp_code shows
%% those as `<<= ...').
printable({rule, _, As, _}) ->
    not lists:any(fun(A) -> element(1, A) =:= pack orelse
				element(1, A) =:= unpack end, As).

print_rule({rule, _, As, G}) ->
    lists:flatten([lists:join(", ", [csp_code:assign(A) || A <- As]),
		   case G of
		       undefined -> [];
		       _ -> [" ? ", candyspeak_eval:text(G)]
		   end]).

%%% ------------------------------------------------------------- new lines

%% A new rung `Coil = _' as line At (what was At on is one further down), on
%% the indentation of the line before it. {ok, Doc} | {error, Message}: Coil
%% has to be something a rule can write.
new_rung(D = #{lines := Ls}, At, Coil) ->
    case from_text(Coil ++ " = _\n") of
	{ok, D1} ->
	    case stmts(D1) of
		[{rule, _, [{'=', _, {field, _, _}, {hole, _}}], undefined} = R] ->
		    Prev = case At > 1 of true -> lists:nth(At - 1, Ls); false -> "" end,
		    Indent = lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, Prev),
		    D2 = shift(D, At, 1),
		    #{lines := Ls2, stmts := Ss, dirty := Dy} = D2,
		    {A, B} = lists:split(At - 1, Ls2),
		    {ok, mark_added(D2#{lines := A ++ [Indent | B], stmts := Ss#{At => R},
					dirty := Dy#{At => true}}, At)};
		_ -> {error, "not a name a rule can write: " ++ Coil}
	    end;
	{error, {_, M}} -> {error, M}
    end.

%% A whole rule from its text as line At, on the indentation of the line
%% before it. {ok, Doc} | {error, Message}.
insert_stmt(D = #{lines := Ls}, At, Text) ->
    case parse(Text ++ "\n") of
	{ok, [R = {rule, _, _, _}]} ->
	    Prev = case At > 1 of true -> lists:nth(At - 1, Ls); false -> "" end,
	    Indent = lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, Prev),
	    D2 = shift(D, At, 1),
	    #{lines := Ls2, stmts := Ss, dirty := Dy} = D2,
	    {A, B} = lists:split(At - 1, Ls2),
	    {ok, mark_added(D2#{lines := A ++ [Indent | B], stmts := Ss#{At => R},
			   dirty := Dy#{At => true}}, At)};
	{ok, _} -> {error, "not one rule: " ++ Text};
	{error, {_, M}} -> {error, M}
    end.

mark_added(D = #{added := A, dirty := Dy}, Ln) ->
    D#{added := A#{Ln => true}, dirty := Dy#{'$lines' => true}}.

%% Line From moved to To, the lines between one step towards where it was.
move_line(D = #{lines := Ls}, From, To) when From =/= To ->
    {A, [L | B]} = lists:split(From - 1, Ls),
    {C, E} = lists:split(To - 1, A ++ B),
    Mv = fun(K) when K =:= From -> To;
	    (K) when is_integer(K), From < To, K > From, K =< To -> K - 1;
	    (K) when is_integer(K), From > To, K >= To, K < From -> K + 1;
	    (K) -> K
	 end,
    Re = fun(M) -> maps:from_list([{Mv(K), V} || {K, V} <- maps:to_list(M)]) end,
    #{stmts := Ss, dirty := Dy, off := Off, added := Ad} = D,
    D#{lines := C ++ [L | E], stmts := Re(Ss), off := Re(Off), added := Re(Ad),
       dirty := (Re(Dy))#{'$lines' => true}};
move_line(D, _, _) -> D.

%% Line N gone, those after it one up.
%% The dirty map's '$lines' says lines came or went, so the file is changed
%% even with no line left to print anew.
delete_line(D = #{lines := Ls, stmts := Ss, dirty := Dy, off := Off, added := Ad}, N) ->
    {A, [_ | B]} = lists:split(N - 1, Ls),
    shift(D#{lines := A ++ B, stmts := maps:remove(N, Ss), off := maps:remove(N, Off),
	     added := maps:remove(N, Ad),
	     dirty := (maps:remove(N, Dy))#{'$lines' => true}}, N + 1, -1).

%% Every statement and mark from line From on moved By lines.
shift(D = #{stmts := Ss, dirty := Dy, off := Off, added := Ad}, From, By) ->
    Mv = fun(M) -> maps:from_list([{case is_integer(K) andalso K >= From of
					 true -> K + By;
					 false -> K
				     end, V} || {K, V} <- maps:to_list(M)])
	 end,
    D#{stmts := Mv(Ss), dirty := Mv(Dy), off := Mv(Off), added := Mv(Ad)}.

%% The line a new rung at the end goes on: before the empty line a file
%% ending in a newline has last.
last_line(#{lines := Ls}) ->
    case lists:last(Ls) of
	"" -> length(Ls);
	_ -> length(Ls) + 1
    end.

%%% ------------------------------------------------------------------ text

nlines(#{lines := Ls}) -> length(Ls).

dirty(#{dirty := Dy}) -> map_size(Dy) > 0.

%% Line N as it would be saved: its statement's line.
line(D, N) -> lists:last(out(D, N)).

%% Line N as the lines it is saved as: a statement printed anew with the
%% comment that was after it above it.
out(#{lines := Ls, stmts := Ss, dirty := Dy}, N) ->
    L = lists:nth(N, Ls),
    case maps:is_key(N, Dy) andalso maps:is_key(N, Ss) of
	true  -> reprint(L, maps:get(N, Ss));
	false -> [L]
    end.

%% The document as the file it is saved as reads: what was added still
%% marked added, on the lines it is on now.
saved(D = #{file := File, added := Ad}) ->
    {ok, D1} = from_text(text(D), File),
    D1#{added := maps:from_list([{saved_line(D, N), true} || N <- maps:keys(Ad)])}.

%% The line N is on in the file as saved.
saved_line(D, N) ->
    lists:sum([length(out(D, K)) || K <- lists:seq(1, N)]).

%% The file: every line as it was, a dirty one printed anew; the rules that
%% are off as a `#disable' line at the end.
text(D = #{off := Off, off_else := Else}) ->
    Src = source(D),
    case lists:usort(Else ++ [N || {Ln, N} <- numbers(D), maps:is_key(Ln, Off)]) of
	[] -> Src;
	Ns ->
	    Nl = case lists:suffix("\n", Src) orelse Src =:= "" of true -> ""; false -> "\n" end,
	    lists:flatten([Src, Nl, "#disable ", lists:join(" ", [integer_to_list(N) || N <- Ns]),
			   "\n"])
    end.

%% The lines alone.
source(D = #{lines := Lines}) ->
    lists:flatten(lists:join("\n", lists:append([out(D, N)
						 || N <- lists:seq(1, length(Lines))]))).

save(D, File) -> file:write_file(File, unicode:characters_to_binary(text(D))).

%% The new statement on the old line's indentation, its comment after.
reprint(Old, S) ->
    Indent = lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, Old),
    Body = case S of
               {rule, _, _, _} -> print_rule(S);
               _ -> caned_decl:print(S)
           end,
    case comment(Old) of
	none -> [Indent ++ Body];
	{_, "//" ++ C} ->
	    wrap(Indent, case C of " " ++ C1 -> C1; _ -> C end, ?WIDTH) ++ [Indent ++ Body]
    end.

%% A `//' outside a string: {the blanks before it, the comment}.
comment(L) -> comment(L, false, []).

comment([], _, _) -> none;
comment([$" | T], Q, Acc) -> comment(T, not Q, [$" | Acc]);
comment("//" ++ _ = C, false, Acc) ->
    Gap = lists:reverse(lists:takewhile(fun(X) -> X =:= $\s orelse X =:= $\t end,
					Acc)),
    {case Gap of [] -> " "; _ -> Gap end, C};
comment([X | T], Q, Acc) -> comment(T, Q, [X | Acc]).

%%% -------------------------------------------------------------- comments

%% Every comment: [{First, Last, Form, Lines}], Form slash | annotate, Lines
%% the comment's text a line each.
comments(D = #{lines := Ls}) ->
    blocks([{N, kind(D, N, L)} || {N, L} <- lists:enumerate(Ls)]).

blocks([{N, {F, T}} | Rest]) ->
    {Same, More} = lists:splitwith(fun({_, {F1, _}}) -> F1 =:= F; (_) -> false end, Rest),
    [{N, N + length(Same), F, [T | [T1 || {_, {_, T1}} <- Same]]} | blocks(More)];
blocks([_ | Rest]) -> blocks(Rest);
blocks([]) -> [].

%% A line's comment: {slash, Text} | {annotate, Text} | none.
kind(D, N, L) ->
    case stmt(D, N) of
        {annotate, _, {'WORD', _, "caned"}, {'WORD', _, "comment"}, {'STR', _, S}} ->
            {annotate, S};
        none ->
            case string:trim(L, leading) of
                "//" ++ T -> {slash, case T of " " ++ T1 -> T1; _ -> T end};
                _ -> none
            end;
        _ -> none
    end.

%% The comment line Ln is in: {First, Last, Form, Lines} | none.
comment_at(D, Ln) ->
    case [C || C = {F, L, _, _} <- comments(D), Ln >= F, Ln =< L] of
        [C] -> C;
        [] -> none
    end.

%% The comment starting on First written anew, its form kept; no text left,
%% the comment gone.
set_comment(D, First, Texts) ->
    {First, Last, Form, _} = comment_at(D, First),
    Indent = indent(lists:nth(First, maps:get(lines, D))),
    replace(D, First, Last, form(Form, Indent, Texts)).

%% A new `//' comment as line At on, on the indentation of the line it goes
%% above (or the one before it, at the end).
new_comment(D = #{lines := Ls}, At, Texts) ->
    Ref = case At =< length(Ls) andalso string:trim(lists:nth(At, Ls)) =/= "" of
              true -> lists:nth(At, Ls);
              false when At > 1 -> lists:nth(At - 1, Ls);
              false -> ""
          end,
    New = form(slash, indent(Ref), Texts),
    D1 = replace(D, At, At - 1, New),
    lists:foldl(fun(N, Dx) -> mark_added(Dx, N) end, D1,
                lists:seq(At, At + length(New) - 1)).

form(_, _, Texts) when Texts =:= [] -> [];
form(slash, Indent, Texts) ->
    case lists:all(fun(T) -> string:trim(T) =:= "" end, Texts) of
        true -> [];
        false -> lists:append([wrap(Indent, T, ?WIDTH) || T <- Texts])
    end;
form(annotate, Indent, Texts) ->
    [Indent ++ "#annotate caned comment \"" ++ [case C of $" -> $'; _ -> C end || C <- T] ++ "\""
     || T <- Texts, string:trim(T) =/= ""].

%% A comment line as `//' lines no wider than Width: broken at blanks, a
%% word longer than the line on a line of its own.
wrap(Indent, T, Width) ->
    P = Indent ++ "//",
    [case L of "" -> P; _ -> P ++ " " ++ L end || L <- wrap_text(Indent, T, Width)].

%% The same lines without the `// ': what a comment's box shows.
wrap_text(Indent, T, Width) ->
    case string:trim(T, trailing) of
        "" -> [""];
        T1 ->
            Lead = lists:takewhile(fun(C) -> C =:= $\s end, T1),
            fill(string:lexemes(T1, " "), Lead, text_width(Indent, Width))
    end.

%% How much of a comment line is text, on that indentation.
text_width(Indent, Width) -> max(20, Width - length(Indent) - 3).

fill([], Acc, _) -> [Acc];
fill([W | Ws], Acc, Room) ->
    case Acc =:= "" orelse lists:all(fun(C) -> C =:= $\s end, Acc) of
        true -> fill(Ws, Acc ++ W, Room);
        false when length(Acc) + 1 + length(W) =< Room -> fill(Ws, Acc ++ " " ++ W, Room);
        false -> [Acc | fill(Ws, W, Room)]
    end.

indent(L) -> lists:takewhile(fun(C) -> C =:= $\s orelse C =:= $\t end, L).

%% Lines First..Last out (none when Last < First), New in their place, each
%% read again for what statement it is.
replace(D = #{lines := Ls}, First, Last, New) ->
    {A, Rest} = lists:split(First - 1, Ls),
    B = lists:nthtail(Last - First + 1, Rest),
    By = length(New) - (Last - First + 1),
    Gone = lists:seq(First, Last),
    D1 = maps:map(fun(K, M) when K =:= stmts; K =:= dirty; K =:= off; K =:= added ->
                          maps:without(Gone, M);
                     (_, V) -> V
                  end, D),
    D2 = shift(D1, Last + 1, By),
    #{stmts := Ss, dirty := Dy} = D2,
    Ss1 = lists:foldl(fun({N, L}, M) ->
                              case parse(L ++ "\n") of
                                  {ok, [S]} -> M#{N => S};
                                  _ -> M
                              end
                      end, Ss, lists:zip(lists:seq(First, First + length(New) - 1), New)),
    D2#{lines := A ++ New ++ B, stmts := Ss1, dirty := Dy#{'$lines' => true}}.

%% Lines First..Last out.
delete_lines(D, First, Last) -> replace(D, First, Last, []).

%% The `// comment' after the statement on Ln, or none.
trailing(#{lines := Ls, stmts := Ss}, Ln) ->
    case maps:is_key(Ln, Ss) of
        true ->
            case comment(lists:nth(Ln, Ls)) of
                {_, C} -> C;
                none -> none
            end;
        false -> none
    end.
