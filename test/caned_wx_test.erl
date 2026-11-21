%%% caned_wx under a display (xvfb-run): the window comes up, keys and the
%%% mouse reach it as the events wx would send, and what it draws is caned's.
%%% With SHOTS=Dir set it leaves a screenshot of each step there.
-module(caned_wx_test).

-export([run/1]).

-include_lib("wx/include/wx.hrl").

run([File]) ->
    {ok, P} = caned_wx:start(File),
    timer:sleep(1200),
    shot("1-start"),
    key(P, ?WXK_RIGHT, 0), key(P, $|, $|),
    [key(P, C, C) || C <- "z==17"],
    key(P, ?WXK_RETURN, 0),
    timer:sleep(500),
    shot("2-branch"),
    %% a drag over the first rung's contacts: the rectangle, then a selection
    mouse(P, left_down, 50, 150, false),            % past the number: the rail
    mouse(P, motion, 330, 175, true),                % the contacts, not the coil
    timer:sleep(300),
    shot("3-drag"),
    mouse(P, left_up, 330, 175, false),
    timer:sleep(500),
    shot("4-selected"),
    expect("the window is up and took the keys and the drag", is_process_alive(P), P),
    case os:find_executable("xclip") of
	false -> ok;
	_ ->
	    Prim = os:cmd("xclip -o -selection primary"),
	    expect("the selection is X11's PRIMARY, for a middle click anywhere",
		   Prim =:= "x + 1 < y && (x > 15 || z == 17)", Prim),
	    ok
    end,
    %% Ctrl + a letter comes as its control code in a char event: ^C is 3.
    %% R1's rung copied onto R2's hole, y = 2's contact cut, saved.
    ctrl(P, 3),
    key(P, ?WXK_DOWN, 0), key(P, ?WXK_DOWN, 0),
    ctrl(P, 22),
    key(P, ?WXK_UP, 0),
    ctrl(P, 24),
    ctrl(P, 19),
    timer:sleep(500),
    shot("5-pasted"),
    {ok, B} = file:read_file(File),
    Want = ["R1 = x + 1 < y && (x > 15 || z == 17)", "y = 2 ? _",
	    "R2 = x + 1 < y && (x > 15 || z == 17)", "R1 = 0, R2 = 0"],
    Got = lists:nthtail(6, string:split(string:trim(binary_to_list(B)), "\n", all)),
    expect("^C ^V ^X ^S: copied onto the hole, cut, saved", Got =:= Want, Got),
    case os:find_executable("xclip") of
	false -> ok;
	_ ->
	    Clip = os:cmd("xclip -o -selection clipboard"),
	    expect("^X put the cut contact on the system clipboard",
		   Clip =:= "x > 3", Clip),
	    %% another program's selection, middle-clicked onto y = 2's hole
	    %% (row 8 of the screen, the hole at column 7: the font's 9 x 24)
	    os:cmd("printf 'a && b' | xclip -i -selection primary"),
	    timer:sleep(300),
	    P ! #wx{event = #wxMouse{type = middle_down, x = 80, y = 8 * 24 + 12}},
	    timer:sleep(300),
	    ctrl(P, 19),
	    timer:sleep(400),
	    {ok, B2} = file:read_file(File),
	    L8 = lists:nth(8, string:split(binary_to_list(B2), "\n", all)),
	    expect("a middle click pastes X11's PRIMARY onto the contact under it",
		   L8 =:= "y = 2 ? a && b", L8),
	    %% `|' on a Swedish keyboard is AltGr + <, which GTK sends as
	    %% Ctrl + Alt: a character, not a command.
	    P ! #wx{event = #wxKey{type = char, keyCode = $|, uniChar = $|,
				   controlDown = true, altDown = true}},
	    timer:sleep(150),
	    [key(P, C, C) || C <- "q1"],
	    key(P, ?WXK_RETURN, 0),
	    ctrl(P, 19),
	    timer:sleep(400),
	    shot("6-altgr"),
	    {ok, B3} = file:read_file(File),
	    L8b = lists:nth(8, string:split(binary_to_list(B3), "\n", all)),
	    expect("AltGr + < is `|': a branch", L8b =:= "y = 2 ? (a || q1) && b", L8b),
	    %% The numbers are handles. ⌥↓ takes y = 2's rule (the cursor's)
	    %% below R2's; then rows 6-7 are rule 1 (R1, a branch), 8-9 R2,
	    %% 10-11 y = 2, 12 R1 = 0. A double click on rule 1's handle: off;
	    %% R1 = 0's handle dragged onto rule 1's row: R1 = 0 first.
	    P ! #wx{event = #wxKey{type = char, keyCode = ?WXK_DOWN, altDown = true}},
	    timer:sleep(150),
	    P ! #wx{event = #wxMouse{type = left_dclick, x = 20, y = 6 * 24 + 12}},
	    timer:sleep(150),
	    mouse(P, left_down, 20, 12 * 24 + 12, false),
	    mouse(P, motion, 20, 6 * 24 + 12, true),
	    mouse(P, left_up, 20, 6 * 24 + 12, false),
	    ctrl(P, 19),
	    timer:sleep(400),
	    shot("7-handles"),
	    {ok, B4} = file:read_file(File),
	    Tail = lists:nthtail(6, string:split(string:trim(binary_to_list(B4)), "\n", all)),
	    WantT = ["R1 = 0, R2 = 0", "R1 = x + 1 < y && (x > 15 || z == 17)",
		     "R2 = x + 1 < y && (x > 15 || z == 17)", "y = 2 ? (a || q1) && b",
		     "#disable 2"],
	    expect("handles: a double click switches off, ⌥↓ and a drag move, the mark goes along",
		   Tail =:= WantT, Tail)
    end,
    exit(P, kill),
    halt(0).

key(P, C, U) ->
    P ! #wx{event = #wxKey{type = char, keyCode = C, uniChar = U}},
    timer:sleep(80).

ctrl(P, C) ->
    P ! #wx{event = #wxKey{type = char, keyCode = C, controlDown = true}},
    timer:sleep(120).

mouse(P, T, X, Y, Down) ->
    P ! #wx{event = #wxMouse{type = T, x = X, y = Y, leftDown = Down}},
    timer:sleep(80).

shot(Name) ->
    case os:getenv("SHOTS") of
	false -> ok;
	Dir -> os:cmd("import -window root " ++ filename:join(Dir, Name ++ ".png"))
    end.

expect(What, true, _)  -> io:format("ok    ~ts~n", [What]);
expect(What, false, D) -> io:format("FAIL  ~ts: ~tp~n", [What, D]), halt(1).
