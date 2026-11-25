%%% What caned offers where something is written: the words a declaration's
%%% field can take, and the parts after `Name.' in a rule.
%%%
%%% The option words are candyspeak's, read from utils/syntax.terms (the
%%% table the C parser is made from): {options, ...} grouped by the field they
%%% set, {triggers, ...}, {option_words, ...}. The parser takes every option
%%% on every declaration and drops what has no field there; which groups MEAN
%%% something on which declaration is here (?GROUPS), as the parts each kind
%%% has are (?PARTS, after include/csp_part.h and csp_view_get_part).

-module(caned_menu).

-export([field/3, add/2, parts/1, kind_of/2, group/1, kinds/0, groups_of/1, words/1,
         heads/1]).

-define(GROUPS, #{digital => [dir, pull, trig, invert],
                  analog => [dir, type, pwm, trig],
                  variable => [type], constant => [type], param => [type],
                  local => [dir, type],
                  field => [type, endian],
                  buffer => [dir, endian]}).

-define(PARTS, #{timer => ["val", "period", "fired"],
                 digital => ["val", "pin", "port", "dir", "pullup", "pulldown", "fired"],
                 analog => ["val", "pin", "port", "dir", "pwm", "fired"],
                 buffer => ["id", "rx", "tx", "dlc", "len", "dir"]}).

-define(TRANSPORTS, ["can 0x100", "can Id", "tcp 5000", "tcp 5000 192.168.1.2", "udp 5000",
                     "udp 5000 192.168.1.2", "uart 0", "uart 0 115200", "console", "repl",
                     "sms Owners", "sms Owners Pin", "i2c 0 0x40 0", "spi 0 1:5 0x9f",
                     "onewire 0:4 Rom"]).

%% The choices for field Key of statement S, in document D.
field(S, Key, D) ->
    K = element(1, S),
    case Key of
        {opt, I} ->
            {_, _, Os} = opts(S),
            Os1 = case length(Os) >= I of true -> Os; false -> [] end,
            case Os1 of
                [] -> [];
                _ -> words(group_of(lists:nth(I, Os1)))
            end;
        transport -> ?TRANSPORTS;
        kw -> [atom_to_list(Ki) || Ki <- kinds()];
        res -> widths(K);
        period -> ["100", "500", "1000", "10000"];
        frame -> [N ++ "[0..7]" || N <- names(D, buffer)];
        init when K =:= param; K =:= variable; K =:= constant; K =:= local -> ["0", "1"];
        _ -> []
    end.

%% The kinds a declaration can be turned into, one into another
%% (caned_decl:convert/2).
kinds() -> [variable, digital, analog, constant, param, local, timer, define].

%% What a new line can begin with after `#' (caned_ui's guided card): the
%% declarations, the objects of D's modules (`#Cnt c0'), then the rest.
heads(D) ->
    [atom_to_list(K) || K <- kinds()] ++ ["buffer", "field"] ++
        [M || {module, _, {'WORD', _, M}} <- caned_doc:stmts(D)] ++
        [M || {module, _, {'WORD', _, M}, _} <- caned_doc:stmts(D)] ++
        ["module", "states", "import", "annotate", "route", "in", "when", "else", "end"].

%% The option groups that mean something on a declaration of kind K.
groups_of(K) -> maps:get(K, ?GROUPS, []).

%% What `+' can put on S: an option of a group it has not got, a width when
%% it has none, a transport on a #buffer with none.
add(S, _D) ->
    K = element(1, S),
    {Has, Res, _} = opts(S),
    Gs = [G || G <- maps:get(K, ?GROUPS, []), not lists:member(G, Has)],
    lists:append([words(G) || G <- Gs]) ++
        [":" ++ W || Res =:= default, W <- widths(K)] ++
        case S of
            {buffer, _, _, _, _, []} -> ?TRANSPORTS;
            _ -> []
        end.

%% {the groups S's options are in, its width, its options}.
opts(S) ->
    {R, Os} = case S of
                  {digital, _, _, _, R0, Os0, _} -> {R0, Os0};
                  {analog, _, _, _, R0, Os0, _} -> {R0, Os0};
                  {variable, _, _, _, R0, Os0, _} -> {R0, Os0};
                  {constant, _, _, _, R0, Os0, _} -> {R0, Os0};
                  {local, _, _, R0, Os0, _} -> {R0, Os0};
                  {param, _, _, R0, Os0, _} -> {R0, Os0};
                  {field, _, _, R0, Os0, _, _} -> {R0, Os0};
                  {buffer, _, _, R0, Os0, _} -> {R0, Os0};
                  _ -> {none, []}
              end,
    {[group_of(O) || O <- Os], R, Os}.

group_of({G, _}) -> G;
group_of(G) -> G.

widths(digital) -> ["1"];
widths(analog) -> ["10", "12", "16"];
widths(buffer) -> ["1", "2", "4", "8", "16", "64", "160"];
widths(field) -> ["1", "8", "16", "32"];
widths(K) when K =:= variable; K =:= constant; K =:= param; K =:= local -> ["8", "16", "32"];
widths(_) -> [].

%% An option word's group: dir | type | endian | pull | trig | pwm | invert
%% | none.
group(W) ->
    case [G || {G, Ws} <- groups(), lists:member(W, Ws)] of
        [G | _] -> G;
        [] -> none
    end.

words(G) -> proplists:get_value(G, groups(), []).

%% The option words by group, from syntax.terms; read once.
groups() ->
    case persistent_term:get(caned_menu_groups, undefined) of
        undefined ->
            Gs = read_groups(),
            persistent_term:put(caned_menu_groups, Gs),
            Gs;
        Gs -> Gs
    end.

read_groups() ->
    Dir = filename:dirname(filename:dirname(code:which(candyspeak_parse))),
    case file:consult(filename:join([Dir, "utils", "syntax.terms"])) of
        {ok, Ts} ->
            Os = hd([L || {options, L} <- Ts]),
            G = fun(F) -> [atom_to_list(W) || {W, F1, _, _} <- Os, F1 =:= F] end,
            [{dir, G(dir)}, {type, G(vt)}, {endian, G(endian)},
             {pull, G(pullup) ++ G(pulldown)}, {pwm, G(pwm)},
             {trig, [atom_to_list(W) || {triggers, L} <- Ts, {W, _} <- L]}] ++
                [{W, [atom_to_list(W)]} || {option_words, L} <- Ts, W <- L];
        _ ->
            [{dir, ["in", "out", "inout"]}, {type, ["unsigned", "integer", "float", "string"]},
             {endian, ["native", "little", "big"]}, {pull, ["pullup", "pulldown"]},
             {pwm, ["pwm"]}, {trig, ["soft", "rising", "falling", "both", "high", "low", "ready"]},
             {invert, ["invert"]}]
    end.

%% The parts a name of kind K has, for `Name.' in a rule.
parts(K) -> maps:get(K, ?PARTS, []).

%% What a name is declared as in D: digital | analog | timer | buffer | ... |
%% none.
kind_of(D, Name) ->
    case [element(1, S) || S <- caned_doc:stmts(D), decl_name(S) =:= Name] of
        [K | _] -> K;
        [] -> none
    end.

names(D, K) -> [N || S <- caned_doc:stmts(D), element(1, S) =:= K, N <- [decl_name(S)], N =/= none].

decl_name(S) when element(1, S) =:= digital; element(1, S) =:= analog;
                  element(1, S) =:= variable; element(1, S) =:= constant;
                  element(1, S) =:= local; element(1, S) =:= param;
                  element(1, S) =:= timer; element(1, S) =:= field;
                  element(1, S) =:= buffer; element(1, S) =:= define ->
    {'WORD', _, N} = element(3, S),
    N;
decl_name(_) -> none.
