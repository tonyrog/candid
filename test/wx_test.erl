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
    P = candid_wx:start("demo/knappar.csp"),
    timer:sleep(3000),
    Ids = ids(P),
    Has = fun(Id) -> ets:lookup(Ids, Id) =/= [] end,
    expect("the window is up and lists its devices",
	   is_process_alive(P) andalso Has("sl_B1") andalso Has("csp_st"),
	   ets:tab2list(Ids)),
    P ! {candid_wx, {bar, "code=ladder"}},
    P ! {candid_wx, {bar, "trace=show"}},
    timer:sleep(?SETTLE),
    Ops = fun() -> case ets:lookup(Ids, code_ops) of
		       [{_, O, _}] -> O;
		       [] -> []
		   end end,
    expect("ladder: the rungs drawn, a contact among them",
	   [T || T = {text, _, _, "B1", _, _} <- Ops()] =/= [], length(Ops())),
    %% A click where B1 is drawn marks it: a frame in `want' around it.
    [{X, Y} | _] = [{X, Y} || {text, X, Y, "B1", _, _} <- Ops()],
    P ! {candid_wx, {code, "xy=" ++ integer_to_list(X + 2) ++ "," ++
			 integer_to_list(Y + 2)}},
    timer:sleep(?SETTLE),
    expect("ladder: a click on a contact marks it",
	   [R || R = {rect, _, _, _, _, _, none, {68, 170, 255}, _} <- Ops()] =/= [],
	   nomatch),
    P ! {candid_wx, {code, "clear"}},
    P ! {candid_wx, {widget, "B1"}},
    P ! {candid_wx, {widget, "B2=1"}},
    timer:sleep(?SETTLE),
    P ! {candid_wx, {code, "sig=Green"}},
    P ! {candid_wx, {code, "solve"}},
    timer:sleep(6000),
    expect("solve finds Green, with a trace table and its walk",
	   Has("tr_tab") andalso Has("tr_ev") andalso is_process_alive(P),
	   nomatch),
    P ! {candid_wx, {code, "table"}},
    P ! {candid_wx, {code, "down"}},
    P ! {candid_wx, {code, "rstep"}},
    timer:sleep(?SETTLE),
    expect("walking and replaying the trace", is_process_alive(P), nomatch),
    P ! {candid_wx, {bar, "theme=light"}},
    P ! {candid_wx, {bar, "code=code"}},
    timer:sleep(?SETTLE),
    expect("the code as text, in the light theme",
	   [T || T = {text, _, _, "B1", _, _} <- Ops()] =/= [] andalso
	       is_process_alive(P), nomatch),
    %% A goal reached at step 0 has no cycle to walk: it must not crash.
    P ! {candid_wx, {code, "clear"}},
    P ! {candid_wx, {code, "sig=B1"}},
    P ! {candid_wx, {code, "solve"}},
    timer:sleep(5000),
    P ! {candid_wx, {code, "down"}},
    timer:sleep(500),
    expect("a trace of one step: nothing to walk, no crash",
	   is_process_alive(P), nomatch),
    %% The rungs and the answer were drawn over several times above: the
    %% theme must not reach a window that is gone, which segfaults.
    P ! {candid_wx, {bar, "theme=dark"}},
    P ! {candid_wx, {bar, "theme=light"}},
    timer:sleep(?SETTLE),
    expect("the theme changed after the code view was redrawn",
	   is_process_alive(P), nomatch),
    %% wx torn down before the emulator: a halt with the window still up
    %% segfaults on the way out, after every check has passed.
    exit(P, kill),
    timer:sleep(500),
    halt(0).

%% The id table: the public ets the panel's process owns.
ids(P) ->
    [T] = [T || T <- ets:all(), ets:info(T, owner) =:= P,
		ets:info(T, name) =:= candid_wx],
    T.

expect(What, true, _)  -> io:format("ok    ~s~n", [What]);
expect(What, false, D) ->
    io:format("FAIL  ~s: ~p~n", [What, D]),
    halt(1).
