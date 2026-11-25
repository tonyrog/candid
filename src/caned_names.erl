%%% The names of a program, as caned writes in it: what a rung uses, what is
%%% declared -- here, in what the file imports, built in -- and where a name
%%% that is not goes. A name written in a rung that nothing declares is
%%% declared for it, `#variable N', its type as the assignment's (caned_ui);
%%% one a letter or two from a declared name may be that one mistyped
%%% (near/2), and is asked about first.

-module(caned_names).

-export([used/2, known/1, unknown/2, declare/4, near/2, rename/4, values/3]).

-define(BUILT_IN, ["State", "INIT", "NORMAL", "FAILSAFE"]).
-define(DECLS, [digital, analog, variable, constant, local, param, timer, field,
		buffer, define, module]).

%% The names rung Ln uses, as read and written, each once, in order.
used(D, Ln) ->
    case caned_doc:stmt(D, Ln) of
	{rule, _, As, G} -> uniq(names(As) ++ names(G));
	_ -> []
    end.

names({field, _, {'WORD', _, N}}) -> [N];
names({field, _, {part, _, {'WORD', _, N}, _}}) -> [N];
names({field, _, _}) -> [];                     % an object's member: c0.N
names({call, _, _, Args}) -> names(Args);       % the function is no name
names(T) when is_tuple(T) -> names(tuple_to_list(T));
names(L) when is_list(L) -> lists:append([names(X) || X <- L]);
names(_) -> [].

uniq(Ns) -> uniq(Ns, []).
uniq([N | T], Seen) ->
    case lists:member(N, Seen) of
	true -> uniq(T, Seen);
	false -> [N | uniq(T, [N | Seen])]
    end;
uniq([], _) -> [].

%% Every name declared: the file's, what it imports, the built in ones.
%% Remembered for a text, as caned_doc:numbers/1 is.
known(D) -> element(1, program(D)).

%% {the names declared, the whole program's statements}: the file parsed
%% with what it imports.
program(D = #{file := File}) ->
    Src = caned_doc:text(D),
    case get(caned_known) of
	{File, Src, P} -> P;
	_ ->
	    Top = filename:absname(File),
	    Ast = case quiet(fun() -> candyspeak:parse_text(Src ++ "\n", Top, [sources]) end) of
		      {ok, A} -> A ++ caned_doc:stmts(D);
		      _ -> caned_doc:stmts(D)            % an #import not found
		  end,
	    P = {lists:usort(?BUILT_IN ++ declared(Ast)), Ast},
	    put(caned_known, {File, Src, P}),
	    P
    end.

%% What X may be given or compared with, rung Ln written: State its states;
%% a #digital 0 and 1; a name the program already gives #define or
%% #constant names -- in a rule, or as it is declared -- those of their
%% families (PRIO_OFF used: every PRIO_...). [] for none.
values(D, _Ln, X) ->
    {_, Ast} = program(D),
    Base = lists:last(string:split(X, ".", all)),
    case Base of
	"State" ->
	    uniq([N || {states, _, Ws} <- Ast, {'WORD', _, N} <- Ws] ++
		     ["INIT", "NORMAL", "FAILSAFE"]);
	_ ->
	    Digital = [N || {digital, _, {'WORD', _, N}, _, _, _, _} <- Ast, N =:= X] =/= [],
	    Defs = uniq([N || {define, _, {'WORD', _, N}, _} <- Ast] ++
			    [N || {constant, _, {'WORD', _, N}, scalar, _, _, _} <- Ast]),
	    Init = [N || {variable, _, {'WORD', _, X1}, _, _, _, {field, _, {'WORD', _, N}}} <- Ast,
			 X1 =:= X, lists:member(N, Defs)],
	    Used = uniq(Init ++ given(caned_doc:stmts(D), X, Defs)),
	    Fams = uniq([family(U) || U <- Used]),
	    [V || Digital, V <- ["0", "1"]] ++
		[N || N <- Defs, lists:any(fun(F) -> lists:prefix(F, N) end, Fams)]
    end.

%% The defines X is given or compared with in the rules.
given(Ss, X, Defs) ->
    lists:append([pairs(S, X, Defs) || S = {rule, _, _, _} <- Ss]).

pairs({Op, _, A, B}, X, Defs) when Op =:= '='; Op =:= '<-'; Op =:= '=='; Op =:= '!=' ->
    case {is(A, X), def(B, Defs), is(B, X), def(A, Defs)} of
	{true, {ok, N}, _, _} -> [N];
	{_, _, true, {ok, N}} -> [N];
	_ -> pairs(A, X, Defs) ++ pairs(B, X, Defs)
    end;
pairs(T, X, Defs) when is_tuple(T) -> pairs(tuple_to_list(T), X, Defs);
pairs(L, X, Defs) when is_list(L) -> lists:append([pairs(E, X, Defs) || E <- L]);
pairs(_, _, _) -> [].

is({field, _, {'WORD', _, X}}, X) -> true;
is(_, _) -> false.

def({field, _, {'WORD', _, N}}, Defs) ->
    case lists:member(N, Defs) of
	true -> {ok, N};
	false -> no
    end;
def(_, _) -> no.

%% A define's family: its name up to its last `_' (PRIO_ of PRIO_OFF); a
%% name without one is a family of its own.
family(N) ->
    case string:split(N, "_", trailing) of
	[F, _] -> F ++ "_";
	[_] -> N
    end.

declared(Ss) ->
    lists:append([decl_names(S) || S <- Ss]).

decl_names({states, _, Ws}) -> [N || {'WORD', _, N} <- Ws];
decl_names({object, _, _, {'WORD', _, O}, _}) -> [O];
decl_names(S) when is_tuple(S), tuple_size(S) >= 3 ->
    case {lists:member(element(1, S), ?DECLS), element(3, S)} of
	{true, {'WORD', _, N}} -> [N];
	_ -> []
    end;
decl_names(_) -> [].

quiet(Fun) ->
    {ok, Null} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Null, self()),
    try Fun()
    catch _:_ -> error
    after group_leader(Old, self()), file:close(Null)
    end.

%% The names rung Ln uses that nothing declares.
unknown(D, Ln) ->
    Known = known(D),
    [N || N <- used(D, Ln), not lists:member(N, Known)].

%% The declared names N may be a mistyped one of: the same but for case;
%% a letter apart (two swapped are one), two in a name over five letters.
%% A name of one or two letters is near nothing else -- A and B are not
%% each other mistyped.
near(D, N) ->
    Max = if length(N) =< 2 -> 0; length(N) =< 5 -> 1; true -> 2 end,
    [K || K <- known(D), K =/= N,
	  string:lowercase(K) =:= string:lowercase(N) orelse
	      (Max > 0 andalso abs(length(K) - length(N)) =< Max andalso dist(K, N) =< Max)].

%% The edit distance, a swap of neighbours one edit (optimal string
%% alignment); names are short.
dist(A, B) ->
    Ta = list_to_tuple(A), Tb = list_to_tuple(B),
    La = length(A), Lb = length(B),
    M0 = maps:from_list([{{I, 0}, I} || I <- lists:seq(0, La)] ++
			    [{{0, J}, J} || J <- lists:seq(0, Lb)]),
    M = lists:foldl(
	  fun({I, J}, Mx) ->
		  Ca = element(I, Ta), Cb = element(J, Tb),
		  Cost = case Ca =:= Cb of true -> 0; false -> 1 end,
		  V0 = lists:min([maps:get({I - 1, J}, Mx) + 1, maps:get({I, J - 1}, Mx) + 1,
				  maps:get({I - 1, J - 1}, Mx) + Cost]),
		  V = case I > 1 andalso J > 1 andalso Ca =:= element(J - 1, Tb)
			  andalso element(I - 1, Ta) =:= Cb of
			  true -> min(V0, maps:get({I - 2, J - 2}, Mx) + 1);
			  false -> V0
		      end,
		  Mx#{{I, J} => V}
	  end, M0, [{I, J} || I <- lists:seq(1, La), J <- lists:seq(1, Lb)]),
    maps:get({La, Lb}, M).

%% N declared for rung Ln: `#variable N', with the type of what the rung
%% assigns it, on a line of its own where the declarations of Ln's scope
%% end -- its module's, or the file's outside any. {ok, D1, Line}.
declare(D, Ln, N, Type) ->
    Text = "#variable " ++ N ++ case Type of
				   none -> "";
				   bit -> ":1";
				   float -> " float";
				   string -> " string"
			       end,
    At = place(D, Ln),
    {ok, D1} = caned_doc:insert_line(D, At, Text),
    {ok, D1, At}.

%% The line a new declaration for Ln goes on: after the last declaration
%% of Ln's scope before it; with none, its #module's next line, or, in the
%% file, the first statement's (above it, under the comments at the top).
place(D, Ln) ->
    Ss = [S || S <- caned_doc:stmts(D), caned_doc:line_of(S) < Ln],
    First = case caned_doc:stmts(D) of
		[S0 | _] -> caned_doc:line_of(S0);
		[] -> Ln
	    end,
    case scope(Ss, [], [], []) of
	{none, [], _} -> min(First, Ln);
	{none, Top, _} -> lists:max(Top) + 1;
	{M, _, []} -> M + 1;
	{_, _, Mine} -> lists:max(Mine) + 1
    end.

%% Walking the statements before the line, the blocks open (#module, #in,
%% #when): {the #module line Ln is in | none, the file's declarations at
%% its top, that module's}.
scope([S | Ss], Stack, Top, Mine) ->
    L = caned_doc:line_of(S),
    case element(1, S) of
	module -> scope(Ss, [{module, L} | Stack], Top, []);
	K when K =:= in; K =:= 'when' -> scope(Ss, [K | Stack], Top, Mine);
	'end' -> scope(Ss, tl_or_none(Stack), Top, Mine);
	K ->
	    case {lists:member(K, ?DECLS -- [module]), Stack} of
		{true, []} -> scope(Ss, Stack, [L | Top], Mine);
		{true, [{module, _} | _]} -> scope(Ss, Stack, Top, [L | Mine]);
		_ -> scope(Ss, Stack, Top, Mine)
	    end
    end;
scope([], Stack, Top, Mine) ->
    case [M || {module, M} <- Stack] of
	[M | _] -> {M, Top, Mine};
	[] -> {none, Top, Mine}
    end.

tl_or_none([_ | T]) -> T;
tl_or_none([]) -> [].

%% Rung Ln with name Old written New, where it is a name.
rename(D, Ln, Old, New) ->
    {rule, L, As, G} = caned_doc:stmt(D, Ln),
    R = ren({rule, L, As, G}, Old, New),
    caned_doc:set_stmt(D, Ln, caned_doc:print_rule(R)).

ren({field, L, {'WORD', L1, Old}}, Old, New) -> {field, L, {'WORD', L1, New}};
ren({field, L, {part, L1, {'WORD', L2, Old}, P}}, Old, New) ->
    {field, L, {part, L1, {'WORD', L2, New}, P}};
ren(T, Old, New) when is_tuple(T) -> list_to_tuple(ren(tuple_to_list(T), Old, New));
ren(L, Old, New) when is_list(L), L =/= [], not is_integer(hd(L)) -> [ren(X, Old, New) || X <- L];
ren(X, _, _) -> X.
