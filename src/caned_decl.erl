%%% A statement that is no rule printed back as candyspeak: the declarations,
%%% the blocks (#module, #in, #when, #else, #end), objects, #import,
%%% #annotate, #disable and immediates `> ...'. One statement, one line,
%%% as the parser reads it -- what caned prints a changed declaration with.
%%% Expressions are candyspeak_eval:text/1's.
%%%
%%% A declaration is printed from its FIELDS (segs/1): {Key, Sep, Text},
%%% Sep what goes before the field, Text the field. What caned shows as the
%%% declaration's card and edits a field at a time:
%%%
%%%   kw          `#digital' -- not edited       name      the name
%%%   arr         `[4]'                          res       the width (`:' Sep)
%%%   {opt, I}    the Ith option word            pins      the pins
%%%   init        what follows `='               period    a timer's
%%%   frame       a #field's `F[0..7]'           transport a #buffer's
%%%   body        the rest of any other statement

-module(caned_decl).

-export([print/1, segs/1, join/1, convert/2]).

print(S) -> join(segs(S)).

%% Declaration S as one of kind K (caned_menu:kinds/0), as text: its name
%% kept, and of the rest what K has -- an array size, a width, the options
%% of K's groups, the pins, a value. A value K must have and S had none of
%% is a hole: `#constant N = _'. A #digital or #analog without pins is left
%% so; they go on as any field does.
convert(S, K) ->
    Segs = segs(S),
    F = fun(Key) -> case lists:keyfind(Key, 1, Segs) of
                        {_, _, T} -> T;
                        false -> ""
                    end
        end,
    Name = F(name),
    Arr = case lists:member(K, [digital, analog, variable, constant]) of
              true -> F(arr);
              false -> ""
          end,
    Res = case {lists:member(K, [analog, variable, constant, param, local]), F(res)} of
              {true, R} when R =/= "" -> ":" ++ R;
              _ -> ""
          end,
    Gs = caned_menu:groups_of(K),
    Opts = [[" ", T] || {{opt, _}, _, T} <- Segs, lists:member(caned_menu:group(T), Gs)],
    Value = case {F(init), F(period)} of
                {"", ""} -> "";
                {"", P} -> P;
                {I, _} -> I
            end,
    Hole = fun("") -> "_"; (V) -> V end,
    Tail = case K of
               digital -> [[" ", F(pins)] || F(pins) =/= ""];
               analog -> [[" ", F(pins)] || F(pins) =/= ""];
               constant -> [" = ", Hole(Value)];
               timer -> [" ", Hole(Value)];
               define -> [" ", Hole(Value)];
               _ -> [[" = ", Value] || Value =/= ""]
           end,
    lists:flatten(["#", atom_to_list(K), " ", Name, Arr, Res, Opts, Tail]).

join(Segs) -> lists:flatten([[Sep, T] || {_, Sep, T} <- Segs]).

segs({digital, _, N, A, R, Os, Ps}) -> card("#digital", N, A, R, Os) ++ fld(pins, " ", pins(Ps));
segs({analog, _, N, A, R, Os, Ps}) -> card("#analog", N, A, R, Os) ++ fld(pins, " ", pins(Ps));
segs({variable, _, N, A, R, Os, X}) -> card("#variable", N, A, R, Os) ++ fld(init, " = ", init(X));
segs({constant, _, N, A, R, Os, X}) -> card("#constant", N, A, R, Os) ++ fld(init, " = ", init(X));
segs({local, _, N, R, Os, X}) -> card("#local", N, scalar, R, Os) ++ fld(init, " = ", init(X));
segs({param, _, N, R, Os, X}) -> card("#param", N, scalar, R, Os) ++ fld(init, " = ", init(X));
segs({timer, _, N, P, X}) ->
    [{kw, "", "#timer"}, {name, " ", w(N)}, {period, " ", x(P)}] ++ fld(init, " = ", init(X));
segs({field, _, N, R, Os, B, Bits}) ->
    card("#field", N, scalar, R, Os) ++ [{frame, " ", [w(B), "[", bits(Bits), "]"]}];
segs({buffer, _, N, R, Os, T}) -> card("#buffer", N, scalar, R, Os) ++ fld(transport, " ", buftype(T));
segs({define, _, N, X}) -> [{kw, "", "#define"}, {name, " ", w(N)}, {init, " ", x(X)}];
segs(S) ->
    [K | Rest] = string:split(lists:flatten(p(S)), " "),
    [{kw, "", K} | fld(body, " ", Rest)].

card(Kw, N, A, R, Os) ->
    [{kw, "", Kw}, {name, " ", w(N)}] ++ fld(arr, "", arr(A)) ++ fld(res, ":", res(R)) ++
        [{{opt, I}, " ", opt(O)} || {I, O} <- lists:enumerate(Os)].

%% A field that is there: none when it is not written.
fld(_, _, []) -> [];
fld(K, Sep, [T]) when is_list(T) -> [{K, Sep, lists:flatten(T)}];
fld(K, Sep, T) -> [{K, Sep, lists:flatten(T)}].

p({module, _, N}) -> ["#module ", w(N)];
p({module, _, N, _}) -> ["#module ", w(N)];
p({states, _, Ns}) -> ["#states ", ws(Ns)];
p({in, _, Ns}) -> ["#in ", ws(Ns)];
p({'when', _, X}) -> ["#when ", x(X)];
p({'else', _}) -> "#else";
p({'end', _}) -> "#end";
p({import, _, name, F}) -> ["#import ", F];
p({import, _, {root, R}, F}) -> ["#import ", R, " ", str(F)];
p({import, _, quoted, F}) -> ["#import ", str(F)];
p({annotate, _, T, W, {'STR', _, S}}) -> ["#annotate ", w(T), " ", w(W), " ", str(S)];
p({annotate, _, T, W, Is}) -> ["#annotate ", w(T), " ", w(W), [[" ", item(I)] || I <- Is]];
p({disable, _, Rs}) -> ["#disable ", lists:join(" ", [rng(R) || R <- Rs])];
p({enable, _, Rs}) -> ["#enable ", lists:join(" ", [rng(R) || R <- Rs])];
p({route, _, A, B}) -> ["#route ", w(A), " ", w(B)];
p({object, _, M, O, Bs}) -> ["#", w(M), " ", w(O), [[" ", bind(B)] || B <- Bs]];
p({immediate, X}) -> ["> ", assign(X)].

w({'WORD', _, N}) -> N.

ws(Ns) -> lists:join(" ", [w(N) || N <- Ns]).

x(X) -> candyspeak_eval:text(X).

str(S) -> [$", S, $"].

%% An assignment, or an expression where one may stand.
assign({Op, _, L, R}) when Op =:= '='; Op =:= '<-' ->
    [x(L), " ", atom_to_list(Op), " ", x(R)];
assign(X) -> x(X).

%% On an object line `Cin=0 A=A & 1': the bindings apart by their blanks.
bind({Op, _, L, R}) -> [x(L), atom_to_list(Op), x(R)];
bind(X) -> x(X).

arr(scalar) -> [];
arr({array_size, _, {'INT', _, N}}) -> ["[", N, "]"].

res(default) -> [];
res(X) -> x(X).

init(undefined) -> [];
init({array, _, Xs}) -> ["{", lists:join(", ", [x(X) || X <- Xs]), "}"];
init(X) -> x(X).

opt({bind, {N, Bits}}) -> ["bind ", w(N), "[", bits(Bits), "]"];
opt({_, A}) -> atom_to_list(A);
opt(A) -> atom_to_list(A).

bits({range, _, {'INT', _, A}, {'INT', _, B}}) -> [A, "..", B];
bits({'INT', _, A}) -> A.

pins(Ps) -> lists:join(" ", [pin(P) || P <- Ps]).

pin({pin, _, {_, _, N}}) -> N;
pin({port_pin, _, {'INT', _, P}, {range, _, {'INT', _, A}, {'INT', _, B}}}) ->
    [P, ":", A, "..", B];
pin({port_pin, _, {'INT', _, P}, {'INT', _, N}}) -> [P, ":", N].

buftype([]) -> [];
buftype([T]) -> bt(T).

bt({can, Id}) -> ["can ", ep(Id)];
bt({i2c, A, B, C}) -> ["i2c ", i(A), " ", i(B), " ", i(C)];
bt({spi, A, {B, C}, D}) -> ["spi ", i(A), " ", i(B), ":", i(C), " ", i(D)];
bt({K, P, Q}) when K =:= udp; K =:= tcp ->
    [atom_to_list(K), " ", ep(P), case Q of
				      {'INT', _, _} -> [" ", i(Q)];
				      _ -> []
				  end];
bt({uart, P, Baud}) ->
    ["uart ", i(P), case Baud of
			{'INT', _, _} -> [" ", i(Baud)];
			_ -> []
		    end];
bt({console}) -> "console";
bt({repl}) -> "repl";
bt({sms, A}) -> ["sms ", w(A)];
bt({sms, A, B}) -> ["sms ", w(A), " ", w(B)];
bt({onewire, {A, B}, N}) -> ["onewire ", i(A), ":", i(B), " ", w(N)].

%% An endpoint: a number, or a #param's name.
ep({field, _, N}) -> w(N);
ep(I) -> i(I).

i({'INT', _, N}) -> N.

item({K, true}) -> w(K);
item({K, {'STR', _, S}}) -> [w(K), "=", str(S)];
item({K, {_, _, V}}) -> [w(K), "=", V].

rng({{'INT', _, A}, {'INT', _, B}}) -> [A, "-", B];
rng({'INT', _, A}) -> A.
