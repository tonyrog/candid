%%% The solver's pane for the desktop: in the panel's dock (candid_wx), made
%%% by the solver's process, so its events go there and a rebuild of the
%%% panel leaves it standing. csp_solve proves, this shows it.

-module(csp_solve_wx).

-include_lib("wx/include/wx.hrl").

-export([pane/4, show/3, results/3, busy/3, clear/2, event/2]).

%% Hidden until show/3: the lines, prove within k, and an answer a line.
pane(H = #{env := Env}, Title, Ks, K0) ->
    wx:set_env(Env),
    {P, S} = candid_wx:dock_pane(H, Title, right, {csp_solve_wx, close}),
    Pid = self(),
    Text = wxTextCtrl:new(P, ?wxID_ANY, [{style, ?wxTE_MULTILINE bor ?wxTE_RICH2}]),
    wxWindow:setFont(Text, candid_wx:font(H)),
    candid_wx:bg(H, Text, {17, 17, 17}),
    candid_wx:fg(H, Text, {238, 238, 238}),
    wxWindow:setToolTip(Text, "a line: assume | invariant | reach, then a "
			"condition on one cycle -- X what it reads, X' what it "
			"leaves, A => B; // a comment"),
    wxSizer:add(S, Text, [{proportion, 1}, {flag, ?wxEXPAND}]),
    Foot = wxBoxSizer:new(?wxHORIZONTAL),
    put(csp_solve_k, K0),
    Sel = candid_wx:menu_btn(H, P, ["k \x{2264} " ++ integer_to_list(X) || X <- Ks],
			     length(lists:takewhile(fun(X) -> X =/= K0 end, Ks)),
			     fun(I) -> Pid ! {csp_solve_wx, k, lists:nth(I, Ks)} end),
    Prove = candid_wx:btn(H, P, "prove",
			  #{click => fun() ->
					     Pid ! {csp_solve_wx, prove,
						    wxTextCtrl:getValue(Text)}
				     end}),
    Clear = candid_wx:btn(H, P, "clear",
			  #{click => fun() -> Pid ! {csp_solve_wx, clear} end}),
    wxWindow:setToolTip(Clear, "the lines and the answers gone, a trace let go"),
    Cancel = candid_wx:btn(H, P, "cancel",
			   #{click => fun() -> Pid ! {csp_solve_wx, cancel} end}),
    wxWindow:setToolTip(Cancel, "stop the run; the lines and the answers so far stay"),
    Busy = wxStaticText:new(P, ?wxID_ANY, "  "),
    candid_wx:fg(H, Busy, {255, 187, 51}),
    [wxSizer:add(Foot, W, [{flag, ?wxRIGHT bor ?wxALIGN_CENTER_VERTICAL},
			   {border, 4}]) || W <- [Prove, Sel, Cancel, Clear]],
    wxSizer:add(Foot, Busy, [{proportion, 1},
			     {flag, ?wxRIGHT bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}]),
    wxSizer:add(S, Foot, [{flag, ?wxEXPAND bor ?wxTOP bor ?wxBOTTOM}, {border, 2}]),
    Res = wxScrolledWindow:new(P),
    wxScrolledWindow:setScrollRate(Res, 0, 10),
    wxWindow:setSizer(Res, wxBoxSizer:new(?wxVERTICAL)),
    candid_wx:bg(H, Res, {27, 27, 27}),
    wxSizer:add(S, Res, [{proportion, 1}, {flag, ?wxEXPAND}]),
    #{h => H, pane => P, text => Text, res => Res, busy => Busy, k => K0}.

show(H, #{pane := P}, On) ->
    candid_wx:dock_show(H, P, On).

%% What the person did. k is kept here: prove says it with the lines.
event(#{k := _}, {csp_solve_wx, k, K})  -> put(csp_solve_k, K), none;
event(#{k := K0}, {csp_solve_wx, prove, Text}) ->
    {prove, Text, case get(csp_solve_k) of undefined -> K0; K -> K end};
event(_P, {csp_solve_wx, pick, I})      -> {pick, I};
event(_P, {csp_solve_wx, close})        -> close;
event(_P, {csp_solve_wx, clear})        -> clear;
event(_P, {csp_solve_wx, cancel})       -> cancel;
event(_P, _Msg)                         -> none.

%% A row a line: its number, its kind and condition, the answer. One with a
%% trace is underlined and shows it on a click.
results(H, #{res := Res}, Rows) ->
    %% The rows' colours go before the rows: the theme sets the colour of
    %% every window it knows, and one that is gone is a segfault.
    candid_wx:forget(H, solve_rows),
    wxWindow:destroyChildren(Res),
    candid_wx:in_scope(H, solve_rows, fun() -> rows(H, Res, Rows) end),
    wxScrolledWindow:fitInside(Res),
    wxWindow:layout(Res),
    ok.

rows(H, Res, Rows) ->
    S = wxWindow:getSizer(Res),
    Pid = self(),
    [begin
	 L = lists:flatten(io_lib:format("~3w  ~-9s ~s", [I, Kind, Text])),
	 A = wxStaticText:new(Res, ?wxID_ANY, L),
	 wxWindow:setFont(A, candid_wx:font(H)),
	 candid_wx:fg(H, A, {170, 170, 170}),
	 B = wxStaticText:new(Res, ?wxID_ANY, "       " ++ Answer ++
				  case Tr of true -> "   \x{25B8} show"; false -> "" end),
	 wxWindow:setFont(B, candid_wx:font(H)),
	 candid_wx:fg(H, B, colour(Cls)),
	 Tr andalso
	     wxWindow:connect(B, left_down,
			      [{callback, fun(_, _) ->
						  Pid ! {csp_solve_wx, pick, I}
					  end}]),
	 Tr andalso wxWindow:setToolTip(B, "show the trace in the code view"),
	 wxSizer:add(S, A, [{flag, ?wxLEFT bor ?wxTOP}, {border, 4}]),
	 wxSizer:add(S, B, [{flag, ?wxLEFT}, {border, 4}])
     end || {I, Kind, Text, Cls, Answer, Tr} <- Rows],
    ok.

%% The lines gone; the answers go by results/3.
clear(_H, #{text := Text}) -> wxTextCtrl:setValue(Text, "").

%% On: true, false, or how far a run is (csp_solve:progress/2).
busy(_H, #{busy := B}, On) ->
    candid_wx:label(B, busy_text(On)).

busy_text(true) -> "...";
busy_text(false) -> "  ";
busy_text(T) -> T.

colour("ok")  -> {119, 221, 119};
colour("bad") -> {255, 119, 119};
colour(_)     -> {221, 187, 102}.
