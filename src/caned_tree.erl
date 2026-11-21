%%% A rung's condition as the ladder sees it, n-ary: an AND across, an OR
%%% stacked, a NOT over one, and a LEAF -- a contact, any expression that is
%%% not one of those three (`x+1 < y', a hole). csp_code:chain/2 flattens
%%% the same way, so a contact here is a contact on the screen.
%%%
%%%   {'and', [T]} | {'or', [T]} | {'not', T} | {leaf, Expr} | {leaf, always}
%%%
%%% `always' is the condition a rule with none has -- `Red = 0, Yellow = 0'
%%% fires every cycle -- drawn as a plain wire. Written into, it is a guard.
%%%
%%% A PATH names a node: the child indexes from the top, 1-based ({'not', T}
%%% has the one child, 1). A RANGE is {Path, From, To}: children From..To of
%%% the and/or at Path -- what a rectangle selects, since `b && c' in the
%%% middle of `a && b && c && d' is no subtree of the binary parse but is
%%% three contacts in a row on the screen.
%%%
%%% Every edit gives back the tree normalised: no and inside an and (or in
%%% an or), no and/or of one, and nothing empty -- what is left of a deleted
%%% last contact is a hole.

-module(caned_tree).

-export([tree/1, expr/1, text/1, norm/1]).
-export([get/2, put/3, leaves/1]).
-export([set_text/3, add_and/2, add_or/2, delete/2, negate/2]).
-export([copy/2, replace/3, range/2, cut/2, in_range/2]).

-define(HOLE, {leaf, {hole, 0}}).

%%% ------------------------------------------------------------ to and fro

tree({'&&', _, _, _} = X) -> {'and', [tree(C) || C <- csp_code:chain('&&', X)]};
tree({'||', _, _, _} = X) -> {'or', [tree(C) || C <- csp_code:chain('||', X)]};
tree({'!', _, X}) ->
    case tree(X) of
	{leaf, _} -> {leaf, {'!', 0, X}};      % `!x' is one contact, normally closed
	T -> {'not', T}
    end;
tree(X) -> {leaf, X}.

expr({'and', [K | Ks]}) ->
    lists:foldl(fun(B, A) -> {'&&', 0, A, expr(B)} end, expr(K), Ks);
expr({'or', [K | Ks]}) ->
    lists:foldl(fun(B, A) -> {'||', 0, A, expr(B)} end, expr(K), Ks);
expr({'not', T}) -> {'!', 0, expr(T)};
expr({leaf, always}) -> {'INT', 0, "1"};
expr({leaf, X}) -> X.

text({leaf, always}) -> "";
text(T) -> candyspeak_eval:text(expr(T)).

norm({Op, Ks}) when Op =:= 'and'; Op =:= 'or' ->
    case [K || K <- lists:append([splice(Op, norm(K)) || K <- Ks]),
	       K =/= {leaf, always}] of
	[] -> ?HOLE;
	[K] -> K;
	Ks1 -> {Op, Ks1}
    end;
norm({'not', T}) ->
    case norm(T) of
	{leaf, X} -> {leaf, {'!', 0, X}};
	T1 -> {'not', T1}
    end;
norm(L = {leaf, _}) -> L.

splice(Op, {Op, Ks}) -> Ks;
splice(_, K) -> [K].

%%% ----------------------------------------------------------------- paths

get(T, []) -> T;
get({'not', T}, [1 | P]) -> get(T, P);
get({_, Ks}, [I | P]) when is_list(Ks) -> get(lists:nth(I, Ks), P).

%% Sub in place of the node at Path; not normalised (the edits do that).
put(_T, [], Sub) -> Sub;
put({'not', T}, [1 | P], Sub) -> {'not', put(T, P, Sub)};
put({Op, Ks}, [I | P], Sub) when is_list(Ks) ->
    {Op, setnth(I, Ks, put(lists:nth(I, Ks), P, Sub))}.

setnth(I, L, X) ->
    {A, [_ | B]} = lists:split(I - 1, L),
    A ++ [X | B].

%% Every leaf's path, in order: the contacts left to right, top to bottom.
leaves(T) -> leaves(T, []).

leaves({leaf, _}, P) -> [lists:reverse(P)];
leaves({'not', T}, P) -> leaves(T, [1 | P]);
leaves({_, Ks}, P) ->
    lists:append([leaves(K, [I | P]) || {I, K} <- lists:zip(lists:seq(1, length(Ks)), Ks)]).

%%% ----------------------------------------------------------------- edits

%% The node at Path written anew as Text (half-written allowed: caned_text).
%% `a && b' typed into a contact of an AND is two contacts of it.
set_text(T, Path, Text) ->
    case caned_text:expr(Text) of
	{ok, X} -> {ok, norm(put(T, Path, tree(X)))};
	E -> E
    end.

%% A new empty contact after the node at Path, in series ({T, HolePath}).
add_and(T, Path) -> add('and', T, Path).

%% A new empty branch under the node at Path, in parallel.
add_or(T, Path) -> add('or', T, Path).

%% On a rung with no condition the new contact is its first.
add(_Op, {leaf, always}, []) -> {?HOLE, []};
add(Op, T, Path) ->
    case parent(Path) of
	{PP, I} ->
	    case get(T, PP) of
		{Op, Ks} ->
		    {A, B} = lists:split(I, Ks),
		    {put(T, PP, {Op, A ++ [?HOLE | B]}), PP ++ [I + 1]};
		_ -> wrap(Op, T, Path)
	    end;
	top -> wrap(Op, T, Path)
    end.

wrap(Op, T, Path) ->
    {put(T, Path, {Op, [get(T, Path), ?HOLE]}), Path ++ [2]}.

parent([]) -> top;
parent(P) -> {lists:droplast(P), lists:last(P)}.

%% The node at Path gone. The last one leaves a hole.
delete(_T, []) -> ?HOLE;
delete(T, Path) ->
    {PP, I} = parent(Path),
    case get(T, PP) of
	{'not', _} -> delete(T, PP);
	{Op, Ks} -> norm(put(T, PP, {Op, lists:sublist(Ks, I - 1) ++ lists:nthtail(I, Ks)}))
    end.

%% Normally open <-> normally closed: `!' on, or off again.
negate(T, Path) ->
    N = case get(T, Path) of
	    {'not', X} -> X;
	    {leaf, {'!', _, X}} -> tree(X);
	    X -> {'not', X}
	end,
    norm(put(T, Path, N)).

%%% ----------------------------------------------------- ranges: copy/paste

%% A range as candyspeak text -- what goes on the clipboard. A whole node is
%% {Path, all}.
copy(T, {Path, all}) -> text(get(T, Path));
copy(T, {Path, From, To}) ->
    {Op, Ks} = get(T, Path),
    text({Op, lists:sublist(Ks, From, To - From + 1)}).

%% The range replaced by Text: `a && b' pasted into an AND is two contacts
%% in it, into an OR one branch of two.
replace(T, {Path, all}, Text) -> set_text(T, Path, Text);
replace(T, {Path, From, To}, Text) ->
    case caned_text:expr(Text) of
	{ok, X} ->
	    {Op, Ks} = get(T, Path),
	    Ks1 = lists:sublist(Ks, From - 1) ++ [tree(X)] ++ lists:nthtail(To, Ks),
	    {ok, norm(put(T, Path, {Op, Ks1}))};
	E -> E
    end.

%% The range a set of contacts makes: the node they all are under, and the
%% run of its children that holds them -- the whole node when that is all of
%% them. What a rectangle over the screen selects.
range(T, Paths = [_ | _]) ->
    CP = prefix(Paths),
    case get(T, CP) of
	{Op, Ks} when Op =:= 'and'; Op =:= 'or' ->
	    Is = [lists:nth(length(CP) + 1, P) || P <- Paths, length(P) > length(CP)],
	    case {lists:min(Is), lists:max(Is)} of
		{1, N} when N =:= length(Ks) -> {CP, all};
		{A, B} -> {CP, A, B}
	    end;
	_ -> {CP, all}
    end.

prefix([P]) -> P;
prefix([P | Ps]) -> lists:foldl(fun common/2, P, Ps).

common([X | A], [X | B]) -> [X | common(A, B)];
common(_, _) -> [].

%% Whether the node at Path is in the range.
in_range(_Path, rule) -> true;                    % the whole rule, coil and all
in_range(Path, {P, all}) -> lists:prefix(P, Path);
in_range(Path, {P, A, B}) ->
    lists:prefix(P, Path) andalso length(Path) > length(P) andalso
	begin I = lists:nth(length(P) + 1, Path), I >= A andalso I =< B end.

%% The range gone; the last of a rung leaves a hole.
cut(T, {Path, all}) -> delete(T, Path);
cut(T, {Path, A, B}) ->
    {Op, Ks} = get(T, Path),
    norm(put(T, Path, {Op, lists:sublist(Ks, A - 1) ++ lists:nthtail(B, Ks)})).
