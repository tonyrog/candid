%%% caned in a terminal: raw keys in, ANSI out, on the alternate screen so
%%% the shell's is there again after. Everything it shows is caned_ui's; this
%%% only reads keys and paints rows.
%%%
%%%   ./caned [-patch] FILE.csp
%%%
%%% The keys come from a reader process a byte at a time. An escape sequence
%%% (an arrow, Del) is read whole; ESC alone is Esc once nothing follows it
%%% within ?ESC_MS.

-module(caned_tty).

-export([main/1]).

-define(ESC_MS, 40).

main(["-patch", File]) -> main(File, patch);
main([File]) -> main(File, edit);
main(_) ->
    io:format(standard_error, "usage: caned [-wx] [-patch] FILE.csp~n", []),
    halt(2).

main(File, Access) ->
    case caned_ui:open(File, Access) of
	{ok, S} ->
	    ok = shell:start_interactive({noshell, raw}),
	    out("\e[?1049h\e[?25l"),
	    Self = self(),
	    spawn_link(fun() -> reader(Self) end),
	    try loop(S)
	    after out("\e[0m\e[?25h\e[?1049l")
	    end,
	    halt(0);
	{error, {L, M}} ->
	    io:format(standard_error, "~s:~w: ~s~n", [File, L, M]),
	    halt(1)
    end.

loop(S) ->
    S1 = paint(S),
    case caned_ui:key(next_key(), S1) of
	{ok, S2} -> loop(S2);
	{quit, _} -> ok
    end.

paint(S) ->
    {Rows, Cols} = term_size(),
    {S1, Lines} = caned_ui:screen(S, Rows, Cols),
    Row = fun(L) -> [[[sgr(A), T] || {A, T} <- L], "\e[0m\e[K"] end,
    out(["\e[H", lists:join("\r\n", [Row(L) || L <- Lines])]),
    S1.

term_size() ->
    R = case io:rows() of {ok, N} -> N; _ -> 24 end,
    C = case io:columns() of {ok, M} -> M; _ -> 80 end,
    {R, C}.

sgr({A, _Path}) -> sgr(A);
sgr(cur)     -> "\e[0;1;7m";
sgr(contact) -> "\e[0;97m";
sgr(hole)    -> "\e[0;33m";
sgr(wire)    -> "\e[0;90m";
sgr(coil)    -> "\e[0;36m";
sgr(coil_cur) -> "\e[0;1;7;36m";
sgr(coil_sel) -> "\e[0;44;97m";
sgr(off)     -> "\e[0;2m";
sgr(comment) -> "\e[0;32m";
sgr(frame)   -> "\e[0;2;32m";
sgr(frame_cur) -> "\e[0;1;33m";
sgr(frame_edit) -> "\e[0;1;97m";
sgr(kw)      -> "\e[0;36m";
sgr(field)   -> "\e[0;97m";
sgr(field_cur) -> "\e[0;1;7m";
sgr(field_edit) -> "\e[0;1;4m";
sgr(add)     -> "\e[0;2m";
sgr(menu)    -> "\e[0;7m";
sgr(menu_sel) -> "\e[0;1;44;97m";
sgr(comment_cur) -> "\e[0;7;32m";
sgr(note)    -> "\e[0;1;32m";
sgr(coil_off) -> "\e[0;2;36m";
sgr(lineno_off) -> "\e[0;31m";
sgr(always)  -> "\e[0;90m";
sgr(always_cur) -> "\e[0;7;90m";
sgr(always_sel) -> "\e[0;44m";
sgr(sel)     -> "\e[0;44;97m";
sgr(lineno)  -> "\e[0;2m";
sgr(text)    -> "\e[0m";
sgr(status)  -> "\e[0;7m";
sgr(help)    -> "\e[0;2m";
sgr(msg)     -> "\e[0;33m";
sgr(error)   -> "\e[0;31m";
sgr(edit)    -> "\e[0;1m";
sgr(_)       -> "\e[0m".

out(IoData) -> io:put_chars(unicode:characters_to_binary(IoData)).

%%% ------------------------------------------------------------------ keys

reader(Pid) ->
    case io:get_chars("", 1) of
	eof -> Pid ! {byte, eof};
	{error, _} -> Pid ! {byte, eof};
	Cs -> [Pid ! {byte, C} || C <- unicode:characters_to_list(Cs)],
	      reader(Pid)
    end.

byte() -> receive {byte, B} -> B end.

byte(Ms) -> receive {byte, B} -> B after Ms -> timeout end.

next_key() ->
    case byte() of
	eof -> $Q;
	27 ->
	    case byte(?ESC_MS) of
		timeout -> esc;
		$[ -> csi([]);
		$O -> ss3(byte());
		_ -> esc
	    end;
	9 -> tab;
	13 -> enter;
	10 -> newline;                          % ^J
	127 -> backspace;
	8 -> backspace;
	C -> C
    end.

%% ESC [ ... final: the arrows, Del; the rest ignored.
csi(Acc) ->
    case byte() of
	B when B >= $@, B =< $~ ->
	    case {lists:reverse(Acc), B} of
		{[], $A} -> up;
		{[], $B} -> down;
		{[], $C} -> right;
		{[], $D} -> left;
		{"3", $~} -> del;
		{"1;2", $C} -> shift_right;
		{"1;2", $D} -> shift_left;
                {"1;3", $A} -> alt_up;
                {"1;3", $B} -> alt_down;
		{[], $Z} -> shift_tab;
		{"5", $~} -> page_up;
		{"6", $~} -> page_down;
		_ -> none
	    end;
	B -> csi([B | Acc])
    end.

ss3($A) -> up;
ss3($B) -> down;
ss3($C) -> right;
ss3($D) -> left;
ss3(_) -> none.
