%%% The log's pane for the desktop: the left of the panel's dock (candid_wx),
%%% made by the log's process, so its events go there and a rebuild of the
%%% panel leaves it standing. candid_log keeps it, this shows it.

-module(candid_log_wx).

-include_lib("wx/include/wx.hrl").

-export([pane/2, show/3, add/4, trim/3, clear/2, event/2]).

%% Hidden until show/3.
pane(H = #{env := Env}, Title) ->
    wx:set_env(Env),
    {P, S} = candid_wx:dock_pane(H, Title, left, {candid_log_wx, close}),
    Log = wxTextCtrl:new(P, ?wxID_ANY, [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY
					 bor ?wxTE_RICH2 bor ?wxTE_WORDWRAP}]),
    wxWindow:setFont(Log, candid_wx:font(H)),
    candid_wx:bg(H, Log, {27, 27, 27}),
    wxSizer:add(S, Log, [{proportion, 1}, {flag, ?wxEXPAND}]),
    Foot = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:addStretchSpacer(Foot),
    Pid = self(),
    Clear = wxButton:new(P, ?wxID_ANY, [{label, "clear"}]),
    wxButton:connect(Clear, command_button_clicked,
		     [{callback, fun(_E, _O) -> Pid ! {candid_log_wx, clear} end}]),
    wxSizer:add(Foot, Clear),
    wxSizer:add(S, Foot, [{flag, ?wxEXPAND bor ?wxTOP}, {border, 2}]),
    #{pane => P, log => Log}.

show(H, #{pane := P}, On) ->
    candid_wx:dock_show(H, P, On).

add(_H, #{log := Log}, Kind, Text) ->
    A = wxTextAttr:new(colour(Kind)),
    wxTextCtrl:setDefaultStyle(Log, A),
    wxTextCtrl:appendText(Log, unicode:characters_to_list(Text) ++ "\n"),
    wxTextAttr:destroy(A).

%% The N oldest lines go.
trim(_H, #{log := Log}, N) ->
    wxTextCtrl:remove(Log, 0, wxTextCtrl:xYToPosition(Log, 0, N)).

clear(_H, #{log := Log}) ->
    wxTextCtrl:clear(Log).

event(_P, {candid_log_wx, close}) -> close;
event(_P, {candid_log_wx, clear}) -> clear;
event(_P, _Msg)                   -> none.

colour(error)   -> {255, 102, 102};
colour(warning) -> {255, 187, 51};
colour(csp)     -> {204, 255, 204};
colour(link)    -> {153, 204, 255};
colour(_)       -> {170, 170, 170}.
