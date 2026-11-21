%%% An expression as it is being typed, a character at a time: what is there
%%% so far, made whole by holes. `x+' is `x + _', `a && (b ||' is
%%% `a && (b || _)'. The ladder is drawn from that after every key, the hole
%%% where the cursor is -- and when `||' comes after an AND the picture
%%% regroups at once, since && binds harder: what you see is how it parses.
%%%
%%% The tokens are completed, not the text: a hole after an operator (or an
%%% open parenthesis, or nothing yet), then the parentheses still open,
%%% closed. Then candyspeak's own parser, as the right side of a rule.

-module(caned_text).

-export([expr/1, complete/1]).

-define(OPS, ['+', '-', '*', '/', '%', '&', '|', '^', '<<', '>>', '==', '!=',
	      '<=', '<', '>', '>=', '&&', '||', '!', '~', '(', ',']).

%% {ok, Expr} | {error, Message}.
expr(Text) ->
    case candyspeak_scan:string(Text) of
	{ok, Toks0, _} ->
	    Toks = [T || T <- Toks0, element(1, T) =/= 'end of line'],
	    Rule = [{'WORD', 1, "Caned"}, {'=', 1}] ++ complete(Toks) ++
		[{'end of line', 1}],
	    case candyspeak_parse:parse(Rule) of
		{ok, [{rule, _, [{'=', _, _, X}], undefined}]} -> {ok, X};
		{ok, _} -> {error, "not an expression"};
		{error, {_, M, D}} -> {error, lists:flatten(M:format_error(D))}
	    end;
	{error, {_, M, D}, _} -> {error, lists:flatten(M:format_error(D))}
    end.

%% The tokens made whole: a hole where an operand is missing at the end, and
%% a `)' for every `(' still open.
complete(Toks) ->
    Hole = case Toks of
	       [] -> [{hole, 1}];
	       _ ->
		   case lists:member(element(1, lists:last(Toks)), ?OPS) of
		       true  -> [{hole, 1}];
		       false -> []
		   end
	   end,
    Open = lists:foldl(fun({'(', _}, N) -> N + 1;
			  ({')', _}, N) -> N - 1;
			  (_, N) -> N
		       end, 0, Toks),
    Toks ++ Hole ++ lists:duplicate(max(Open, 0), {')', 1}).
