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
    Clear = candid_wx:btn(H, P, "clear",
			  #{click => fun() -> Pid ! {candid_log_wx, clear} end}),
    wxSizer:add(Foot, Clear),
    wxSizer:add(S, Foot, [{flag, ?wxEXPAND bor ?wxTOP}, {border, 2}]),
    candid_wx:rich(H, Log, fun colour/2),
    #{pane => P, log => Log}.

show(H, #{pane := P}, On) ->
    candid_wx:dock_show(H, P, On).

add(H, #{log := Log}, Kind, Text) ->
    candid_wx:rich_add(H, Log, Kind, unicode:characters_to_list(Text) ++ "\n").

%% The N oldest lines go.
trim(H, #{log := Log}, N) ->
    candid_wx:rich_trim(H, Log, N).

clear(H, #{log := Log}) ->
    candid_wx:rich_clear(H, Log).

event(_P, {candid_log_wx, close}) -> close;
event(_P, {candid_log_wx, clear}) -> clear;
event(_P, _Msg)                   -> none.

%% Each kind's colour on the dark ground, and on the light one: the dark
%% ones turned over would come out too pale to read on white.
colour(true, Kind)  -> light(Kind);
colour(false, Kind) -> dark(Kind).

dark(error)   -> {255, 102, 102};
dark(warning) -> {255, 187, 51};
dark(csp)     -> {204, 255, 204};
dark(link)    -> {153, 204, 255};
dark(_)       -> {170, 170, 170}.

light(error)   -> {190, 30, 30};
light(warning) -> {150, 80, 0};
light(csp)     -> {20, 100, 30};
light(link)    -> {10, 70, 160};
light(_)       -> {70, 70, 70}.
