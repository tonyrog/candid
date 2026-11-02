%%% The chat's pane for the desktop: the right of the panel's dock
%%% (candid_wx), made by the chat's process, so its events go there and a
%%% rebuild of the panel leaves it standing. csp_chat converses, this shows it.

-module(csp_chat_wx).

-include_lib("wx/include/wx.hrl").

-export([pane/2, show/3, say/4, busy/3, event/2]).

%% Hidden until show/3. Enter sends, shift+Enter is a new line.
pane(H = #{env := Env}, Title) ->
    wx:set_env(Env),
    {P, S} = candid_wx:dock_pane(H, Title, right, {csp_chat_wx, close}),
    Log = wxTextCtrl:new(P, ?wxID_ANY, [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY
					 bor ?wxTE_RICH2 bor ?wxTE_WORDWRAP}]),
    wxWindow:setFont(Log, candid_wx:font(H)),
    candid_wx:bg(H, Log, {27, 27, 27}),
    wxSizer:add(S, Log, [{proportion, 1}, {flag, ?wxEXPAND}]),
    Foot = wxBoxSizer:new(?wxHORIZONTAL),
    In = wxTextCtrl:new(P, ?wxID_ANY, [{style, ?wxTE_MULTILINE},
				       {size, {-1, 60}}]),
    wxWindow:setFont(In, candid_wx:font(H)),
    candid_wx:bg(H, In, {17, 17, 17}),
    candid_wx:fg(H, In, {238, 238, 238}),
    wxWindow:setToolTip(In, "Enter sends, shift+Enter is a new line"),
    Pid = self(),
    wxWindow:connect(In, key_down,
		     [{callback,
		       fun(#wx{event = #wxKey{keyCode = ?WXK_RETURN,
					      shiftDown = false}}, _O) ->
			       Pid ! {csp_chat_wx, send, wxTextCtrl:getValue(In)},
			       wxTextCtrl:clear(In);
			  (_E, O) -> wxEvent:skip(O)
		       end}]),
    wxSizer:add(Foot, In, [{proportion, 1}, {flag, ?wxEXPAND}]),
    Busy = wxStaticText:new(P, ?wxID_ANY, "  ", [{size, {30, -1}}]),
    candid_wx:fg(H, Busy, {255, 187, 51}),
    wxSizer:add(Foot, Busy, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL}, {border, 6}]),
    wxSizer:add(S, Foot, [{flag, ?wxEXPAND bor ?wxTOP}, {border, 2}]),
    #{pane => P, log => Log, input => In, busy => Busy}.

show(H, #{pane := P}, On) ->
    candid_wx:dock_show(H, P, On).

%% What the person did: a line to send, or the pane closed.
event(_P, {csp_chat_wx, send, Text}) -> {send, Text};
event(_P, {csp_chat_wx, close})      -> close;
event(_P, _Msg)                      -> none.

say(_H, #{log := Log}, Who, Text) ->
    Col = case Who of
	      user      -> {153, 204, 255};
	      assistant -> {238, 238, 238};
	      note      -> {136, 136, 136};
	      error     -> {255, 102, 102}
	  end,
    Prefix = case Who of user -> "\n> "; note -> "  \x{b7} "; _ -> "" end,
    A = wxTextAttr:new(Col),
    wxTextCtrl:setDefaultStyle(Log, A),
    wxTextCtrl:appendText(Log, Prefix ++ unicode:characters_to_list(Text) ++ "\n"),
    wxTextAttr:destroy(A).

busy(_H, #{busy := B}, On) ->
    candid_wx:label(B, case On of true -> "..."; false -> "  " end).
