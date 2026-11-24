%%% The keys of caned's window, and candid's code view, by NAME: what a key
%%% is called, in Emacs's way -- "C-a" (ctrl), "M-up" (alt), "S-tab"
%%% (shift, on a key that is no character), "pgdn", "x" -- and what each
%%% name does: a command caned_ui:key/2 takes. A character not in the table
%%% is itself. The table is defaults/0 with what the settings say on top
%%% (candid's {keys, [{Name, Command}]}), so
%%%
%%%   {keys, [{"C-n", down}, {"C-p", up}, {"C-f", right}, {"C-b", left},
%%%           {"C-a", rung_start}, {"C-e", rung_end}]}.
%%%
%%% gives Emacs's moves. A command none takes a key away.
%%%
%%% A name may be a SEQUENCE, keys apart by a blank: "C-x C-s". Its first
%%% keys are then a prefix: they wait for the next (feed/3), and win over
%%% the same key bound alone -- with "C-x C-s" in the table C-x no longer
%%% cuts. The atom emacs in the list brings emacs/0's table in, what comes
%%% after it over that:
%%%
%%%   {keys, [emacs, {"C-z", $u}]}.
%%%
%%% show/0 (`caned -keys') is a window that shows what wx says of each key
%%% pressed, and the name and command it is given.

-module(caned_keys).

-export([name/1, command/2, table/1, settings/0, defaults/0, emacs/0, feed/3, show/0]).

-include_lib("wx/include/wx.hrl").

defaults() ->
    [{"left", left}, {"right", right}, {"up", up}, {"down", down},
     {"S-left", shift_left}, {"S-right", shift_right},
     {"M-up", alt_up}, {"M-down", alt_down},
     {"return", enter}, {"S-return", newline}, {"escape", esc},
     {"backspace", backspace}, {"delete", del}, {"insert", $o},
     {"tab", tab}, {"S-tab", shift_tab},
     {"pgup", page_up}, {"pgdn", page_down},
     {"home", doc_start}, {"end", doc_end},
     {"C-home", doc_start}, {"C-end", doc_end},
     {"C-c", copy}, {"C-x", cut}, {"C-v", paste}, {"C-j", newline},
     {"C-z", $u}, {"C-r", 18}, {"C-s", $s}].

%% Emacs's keys, as far as caned has their like. C-g, as Esc, leaves what
%% is being written; C-k takes the rung out.
emacs() ->
    [{"C-f", right}, {"C-b", left}, {"C-n", down}, {"C-p", up},
     {"C-a", rung_start}, {"C-e", rung_end}, {"M-<", doc_start}, {"M->", doc_end},
     {"C-v", page_down}, {"M-v", page_up},
     {"C-d", del}, {"C-k", $D}, {"C-o", $o}, {"C-g", esc}, {"C-m", enter},
     {"C-w", cut}, {"M-w", copy}, {"C-y", paste},
     {"C-/", $u}, {"C-x u", $u}, {"C-x C-s", $s}, {"C-x C-c", $q}].

%% The table: the defaults, Overrides ([{Name, Command}] and emacs) over
%% them, a later one over an earlier.
table(Overrides) ->
    lists:foldl(fun(emacs, T) -> maps:merge(T, maps:from_list(emacs()));
                   ({N, C}, T) when is_list(N) -> T#{N => C};
                   (_, T) -> T
                end, maps:from_list(defaults()), Overrides).

%% The table by candid's settings ({keys, ...}); the defaults without.
settings() ->
    table(try candid:pref(keys) of
              L when is_list(L) -> L;
              _ -> []
          catch _:_ -> []
          end).

%% The key Name after the keys Pending (names, a prefix so far):
%% {command, Command} -- none when it does nothing -- | {prefix, Keys} to
%% wait for the next | {undefined, Sequence}.
feed(Name, Pending, Table) ->
    Keys = Pending ++ [Name],
    Seq = lists:join(" ", Keys),
    S = lists:flatten(Seq),
    case [K || K <- maps:keys(Table), lists:prefix(S ++ " ", K)] of
        [_ | _] -> {prefix, Keys};
        [] ->
            case {maps:find(S, Table), Pending} of
                {{ok, C}, _} -> {command, C};
                {error, []} -> {command, command(Name, Table)};
                {error, _} -> {undefined, S}
            end
    end.

%% What the key called Name does in Table: a command, or none.
command(Name, Table) ->
    case maps:find(Name, Table) of
        {ok, C} -> C;
        error ->
            case Name of
                [C] when C >= $\s -> C;
                _ -> none
            end
    end.

%% A wx key's name. In a char event Ctrl + a letter comes as its control
%% code, 1..26 (^C is 3); some ports give the letter: both are "C-c". AltGr
%% arrives as Ctrl + Alt on GTK -- `|' on a Swedish keyboard is AltGr + <
%% -- so that is the character it gives, no modifier.
name(#wxKey{keyCode = Code, uniChar = U, controlDown = Ctrl, altDown = Alt,
            shiftDown = Shift}) ->
    AltGr = Ctrl =:= true andalso Alt =:= true,
    C = Ctrl =:= true andalso not AltGr,
    M = Alt =:= true andalso not AltGr,
    case special(Code) of
        none when C, Code >= 1, Code =< 26 -> "C-" ++ [Code + $a - 1];
        none when C, Code >= $A, Code =< $Z -> "C-" ++ [Code - $A + $a];
        none when C, Code >= $\s, Code < 127 -> "C-" ++ [Code];
        none when is_integer(U), U >= $\s -> [$M, $- || M] ++ [U];
        none -> "";
        N -> [$C, $- || C] ++ [$M, $- || M] ++ [$S, $- || Shift =:= true] ++ N
    end.

special(?WXK_LEFT) -> "left";
special(?WXK_RIGHT) -> "right";
special(?WXK_UP) -> "up";
special(?WXK_DOWN) -> "down";
special(?WXK_RETURN) -> "return";
special(?WXK_NUMPAD_ENTER) -> "return";
special(?WXK_ESCAPE) -> "escape";
special(?WXK_BACK) -> "backspace";
special(?WXK_DELETE) -> "delete";
special(?WXK_NUMPAD_DELETE) -> "delete";
special(?WXK_INSERT) -> "insert";
special(?WXK_NUMPAD_INSERT) -> "insert";
special(?WXK_TAB) -> "tab";
special(?WXK_PAGEUP) -> "pgup";
special(?WXK_NUMPAD_PAGEUP) -> "pgup";
special(?WXK_PAGEDOWN) -> "pgdn";
special(?WXK_NUMPAD_PAGEDOWN) -> "pgdn";
special(?WXK_HOME) -> "home";
special(?WXK_NUMPAD_HOME) -> "home";
special(?WXK_END) -> "end";
special(?WXK_NUMPAD_END) -> "end";
special(?WXK_F1) -> "f1";
special(_) -> none.

%%% ------------------------------------------------------------ show

%% A window that lists each key as wx gives it -- key_down and char, the
%% codes, the modifiers -- and the name and the command caned makes of it,
%% by the settings' table. Printed on stdout too.
show() ->
    _ = wx:new(),
    F = wxFrame:new(wx:null(), ?wxID_ANY, "caned -keys", [{size, {900, 500}}]),
    T = wxTextCtrl:new(F, ?wxID_ANY, [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY
                                       bor ?wxWANTS_CHARS}]),
    wxWindow:setFont(T, wxFont:new(10, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
                                   ?wxFONTWEIGHT_NORMAL)),
    wxWindow:connect(T, key_down, [{skip, true}]),     % and on to make the char
    wxWindow:connect(T, char, [{skip, false}]),
    wxFrame:connect(F, close_window),
    wxFrame:show(F),
    wxWindow:setFocus(T),
    Table = settings(),
    Say = fun(Line) -> io:format("~ts~n", [Line]), wxTextCtrl:appendText(T, Line ++ "\n") end,
    Say("press keys; the window's close ends it"),
    show_loop(Say, Table, []).

show_loop(Say, Table, Pend) ->
    receive
        #wx{event = #wxClose{}} -> wx:destroy();
        #wx{event = K = #wxKey{type = Type, keyCode = C, uniChar = U, rawCode = R,
                               controlDown = Ct, altDown = A, shiftDown = Sh, metaDown = M}} ->
            Mods = [X || {true, X} <- [{Ct, "ctrl"}, {A, "alt"}, {Sh, "shift"}, {M, "meta"}]],
            Head = io_lib:format("~-8s keyCode ~-5w uniChar ~-5w raw ~-5w ~-16s",
                                 [Type, C, U, R, lists:join("+", Mods)]),
            case Type of
                char ->
                    N = name(K),
                    {What, Pend1} = case feed(N, Pend, Table) of
                                        {prefix, P} -> {"prefix, waits", P};
                                        {command, Cmd} when is_integer(Cmd), Cmd >= $\s ->
                                            {[$$, Cmd], []};
                                        {command, Cmd} -> {io_lib:format("~p", [Cmd]), []};
                                        {undefined, Sq} -> {Sq ++ " is undefined", []}
                                    end,
                    Say(lists:flatten([Head, io_lib:format("name ~-10s -> ", ["\"" ++ N ++ "\""]), What])),
                    show_loop(Say, Table, Pend1);
                _ ->
                    Say(lists:flatten(Head)),
                    show_loop(Say, Table, Pend)
            end;
        _ -> show_loop(Say, Table, Pend)
    end.
