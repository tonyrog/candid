%% candid_wx under a virtual display (make test-wx runs it in xvfb-run): the
%% whole loop in a real window -- a csp, clicks, the code view, a solve and
%% its trace, the theme -- checked through the window's own id table, the
%% names the code view paints by.

-module(wx_test).
-export([run/0]).

-define(SETTLE, 1500).

run() ->
    _ = application:load(candid),
    application:set_env(candid, chat, off),
    P = candid_wx:start(["demo/knappar.csp"]),
    timer:sleep(3000),
    Ids = ids(P),
    Has = fun(Id) -> ets:lookup(Ids, Id) =/= [] end,
    Lit = fun(L) -> [On || {{btn, _}, #{label := L1, on := On}, _}
			       <- ets:tab2list(Ids), L1 =:= L] end,
    expect("the window is up and lists its devices",
	   is_process_alive(P) andalso Has("sl_B1") andalso Has("csp_st"),
	   ets:tab2list(Ids)),
    P ! {candid_wx, {bar, "trace=show"}},
    timer:sleep(?SETTLE),
    Ops = fun() -> csp_code_wx:ops(Ids) end,
    expect("ladder: the rungs drawn, a contact among them",
	   [T || T = {text, _, _, "B1", _, _} <- Ops()] =/= [], length(Ops())),
    %% A click where B1 is drawn: no frame round it -- the solver is where
    %% conditions are written now.
    [{X, Y} | _] = [{X, Y} || {text, X, Y, "B1", _, _} <- Ops()],
    P ! {candid_wx, {code, "xy=" ++ integer_to_list(X + 2) ++ "," ++
			 integer_to_list(Y + 2)}},
    timer:sleep(?SETTLE),
    expect("ladder: a click on a contact marks nothing",
	   is_process_alive(P) andalso
	       [R || R = {rect, _, _, _, _, _, none, {68, 170, 255}, _} <- Ops()] =:= [],
	   nomatch),
    %% A zoom at the right of a view at its left edge: it stays there, the
    %% code's start in sight. Called here as the menu's callback calls it.
    {dictionary, Dict} = process_info(P, dictionary),
    wx:set_env(proplists:get_value(wx_env, Dict)),
    [{_, {Canvas, Right}, _}] = ets:lookup(Ids, code_canvas),
    Frame = top(Right),
    {Fw, Fh} = wxWindow:getSize(Frame),
    wxWindow:setSize(Frame, {Fw - 600, Fh}),      % narrower than the rungs
    timer:sleep(?SETTLE),
    wxScrolledWindow:scroll(Right, 0, 0),
    {Rw, _} = wxWindow:getClientSize(Right),
    csp_code_wx:zoom_at(#{ids => Ids}, Canvas, Right, 2.0, {Rw - 20, 20}),
    {Zx, _} = wxScrolledWindow:getViewStart(Right),
    {Cw, _} = wxWindow:getSize(Canvas),
    expect("zoom: a view at its left edge stays there",
	   Zx =:= 0 andalso Cw > Rw, {Zx, Cw, Rw}),
    csp_code_wx:zoom_at(#{ids => Ids}, Canvas, Right, 1.0, {20, 20}),
    %% Wheel turns quicker than a view is drawn: added up and scrolled
    %% together, all of them.
    wxWindow:setSize(Frame, {Fw, Fh - 300}),        % lower than the rungs
    timer:sleep(?SETTLE),
    wxScrolledWindow:scroll(Right, 0, 0),
    Hw = #{ids => Ids, env => wx:get_env()},
    [csp_code_wx:wheel(Hw, Canvas, Right, 10) || _ <- lists:seq(1, 6)],
    timer:sleep(?SETTLE),
    {_, Wy} = wxScrolledWindow:getViewStart(Right),
    {_, Wu} = wxScrolledWindow:getScrollPixelsPerUnit(Right),
    expect("wheel: six turns of 10 px scroll 60 px",
           Wy * Wu =:= 60 andalso not ets:member(Ids, code_wheeling),
           {Wy, Wu, wxWindow:getSize(Canvas), wxWindow:getClientSize(Right)}),
    wxScrolledWindow:scroll(Right, 0, 0),
    wxWindow:setSize(Frame, {Fw, Fh}),
    P ! {candid_wx, {widget, "B1"}},
    P ! {candid_wx, {widget, "B2=1"}},
    timer:sleep(?SETTLE),
    %% The solver's pane, its process linked to the panel's.
    P ! {candid_wx, {bar, "solver=toggle"}},
    timer:sleep(?SETTLE),
    [Solver] = [L || L <- element(2, process_info(P, links)), is_pid(L),
		     process_info(L, current_function) =:= {current_function,
							    {csp_solve, loop, 1}}],
    expect("the solver's button lit while its pane is shown",
	   Lit("solver") =:= [true], Lit("solver")),
    Solver ! {csp_solve_wx, prove, "reach Green\nreach B1\n"},
    timer:sleep(8000),
    Solver ! {csp_solve_wx, pick, 1},
    timer:sleep(?SETTLE),
    expect("the solver finds Green, the code view gets its trace and walk",
	   Has("tr_tab") andalso Has("tr_ev") andalso is_process_alive(P),
	   nomatch),
    P ! {candid_wx, {code, "table"}},
    P ! {candid_wx, {code, "down"}},
    P ! {candid_wx, {code, "replay"}},
    P ! {candid_wx, {code, "rstep"}},
    timer:sleep(?SETTLE),
    expect("walking and replaying the trace", is_process_alive(P), nomatch),
    P ! {candid_wx, {bar, "theme=light"}},
    timer:sleep(?SETTLE),
    expect("the ladder again, in the light theme",
	   [T || T = {text, _, _, "B1", _, _} <- Ops()] =/= [] andalso
	       is_process_alive(P), nomatch),
    Solver ! {csp_solve_wx, pick, 2},
    timer:sleep(?SETTLE),
    P ! {candid_wx, {code, "down"}},
    timer:sleep(500),
    expect("another trace picked, walked: no crash", is_process_alive(P), nomatch),
    %% Cleared: the trace goes as it does when closed, the pane stays open
    %% and a pick of a line that is gone picks nothing.
    Solver ! {csp_solve_wx, clear},
    timer:sleep(?SETTLE),
    Solver ! {csp_solve_wx, pick, 1},
    timer:sleep(?SETTLE),
    expect("clear: the trace let go, the pane still open",
	   not Has("tr_tab") andalso Lit("solver") =:= [true] andalso
	       is_process_alive(P), {Has("tr_tab"), Lit("solver")}),
    Solver ! {csp_solve_wx, prove, "reach Green\n"},
    timer:sleep(5000),
    Solver ! {csp_solve_wx, pick, 1},
    timer:sleep(?SETTLE),
    expect("and it proves again after", Has("tr_tab"), nomatch),
    %% Closed: the trace goes, and csp is put back from the replay.
    Solver ! {csp_solve_wx, close},
    timer:sleep(?SETTLE),
    expect("the solver closed, the panel and csp as before",
	   is_process_alive(P) andalso is_process_alive(Solver), nomatch),
    expect("the solver's button dark once its pane is closed",
	   Lit("solver") =:= [false], Lit("solver")),
    %% The rungs and the answer were drawn over several times above: the
    %% theme must not reach a window that is gone, which segfaults.
    P ! {candid_wx, {bar, "theme=dark"}},
    P ! {candid_wx, {bar, "theme=light"}},
    timer:sleep(?SETTLE),
    expect("the theme changed after the code view was redrawn",
	   is_process_alive(P), nomatch),
    %% The editor (caned) on the code view's canvas, its rungs lit by what
    %% the program does: B1 set, its contact green.
    P ! {candid_wx, {bar, "theme=dark"}},
    timer:sleep(?SETTLE),
    expect("edit: the editor drawn on the canvas, the file's lines in it",
	   [T || T = {text, _, _, "#digital", _, _} <- Ops()] =/= [], nomatch),
    P ! {candid_wx, {widget, "B1=1"}},
    P ! {candid_wx, {code, {key, down}}},
    timer:sleep(?SETTLE),
    expect("edit: a contact that holds is lit",
	   [R || R = {rect, _, _, _, _, _, _, {51, 255, 51}, _} <- Ops()] =/= [], nomatch),
    P ! {candid_wx, {widget, "B1=0"}},
    timer:sleep(?SETTLE),
    %% Written in the editor, saved by the bar's save as: the editor's text
    %% is what is written, not the file as it was read.
    [P ! {candid_wx, {code, {key, K}}} || K <- [$/ | "saved by the bar"] ++ [enter]],
    timer:sleep(?SETTLE),
    %% Save as redraws the file tabs. The old ones' entries must go with
    %% them: New walks every window the id table knows, and a gone one is a
    %% segfault (solver open, save as, new did it).
    P ! {candid_wx, {bar, "solver=toggle"}},
    Saved = filename:absname("test/ebin/wx_saved.csp"),
    Btns = fun() -> length([W || {{btn, W}, _, _} <- ets:tab2list(Ids)]) end,
    P ! {candid_wx, {bar, "saveas=" ++ Saved}},
    timer:sleep(?SETTLE),
    B0 = Btns(),
    {ok, SavedText} = file:read_file(Saved),
    expect("save as writes what the editor has written",
	   string:find(SavedText, <<"saved by the bar">>) =/= nomatch, SavedText),
    P ! {candid_wx, {bar, "saveas=" ++ Saved}},
    timer:sleep(?SETTLE),
    expect("save as redraws the tabs and leaves no dead ones behind",
	   Btns() =:= B0, {B0, Btns()}),
    %% The preview counts its pages where it has a printer's DC; its tool
    %% bar asks for pages where there is none, and measuring there was a
    %% segfault.
    P ! {candid_wx, {bar, "print"}},
    timer:sleep(?SETTLE),
    Preview = wxWindow:findWindowByLabel("print wx_saved.csp"),
    expect("print: a preview of the code view, and wx still up",
	   is_process_alive(P) andalso not wx:is_null(Preview), Preview),
    wx:is_null(Preview) orelse wxWindow:destroy(Preview),
    P ! {candid_wx, {bar, "new"}},
    timer:sleep(?SETTLE),
    expect("new after save as, the solver open: no crash", is_process_alive(P),
	   nomatch),
    expect("new starts from a program: its comment and its rung in the editor",
	   [T || T = {text, _, _, Tx, _, _} <- Ops(), string:find(Tx, "A new program") =/= nomatch]
	   =/= [], [Tx || {text, _, _, Tx, _, _} <- Ops()]),
    %% wx torn down before the emulator: a halt with the window still up
    %% segfaults on the way out, after every check has passed.
    exit(P, kill),
    timer:sleep(500),
    halt(0).

top(W) ->
    Up = wxWindow:getParent(W),
    case wx:is_null(Up) of
	true -> W;
	false -> top(Up)
    end.

%% The id table: the public ets the panel's process owns.
ids(P) ->
    [T] = [T || T <- ets:all(), ets:info(T, owner) =:= P,
		ets:info(T, name) =:= candid_wx],
    T.

expect(What, true, _)  -> io:format("ok    ~s~n", [What]);
expect(What, false, D) ->
    io:format("FAIL  ~s: ~p~n", [What, D]),
    halt(1).
