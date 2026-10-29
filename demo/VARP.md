# Proving the house

`home.csp` says the house should never reach FAILSAFE. `home.varp` is the same
system as a varp model, and it proves it.

    cd ~/erlang/varp
    ./priv/varp.sh bmc --induction ~/work/candyspeak/tools/panel/demo/home.varp

    bmc: proved by 1-induction
    % TRUE

And with one rule deleted from the program -- `Heater__Orange = 0 ? LivingWindow`
-- the proof becomes a trace:

    ./priv/varp.sh bmc ~/work/candyspeak/tools/panel/demo/home_bug.varp

    bmc: counterexample at k=2
      step  St  Temp  input
         0   3     -
         1   3   127  Heater WinWas Window
         2   2   127  Heater WinWas Window
    % 1

Read it as: the house starts in `Home` (3). In step 1 the window opens while the
indoor temperature reads 127 -- below the 200 threshold -- so the heater comes on
and `WinWas` records the window. In step 2 the violation has persisted for a
cycle, and the state goes to 2, FAILSAFE.

That is the whole loop: a property stated in the program, proved when it holds,
and a concrete sequence of inputs when it does not.

## How candyspeak maps onto varp

| candyspeak | varp |
|---|---|
| a leaf's committed value | `state` |
| a sensor (`digital in`, `analog in`) | `input` |
| one cycle | `next` |
| reads the COMMITTED state | a condition reads `X`, an assignment writes `next(X)` |
| several rules, last one wins | a priority chain: later guards negated in earlier branches |
| `#in FAILSAFE` and stickiness | an absorbing state |
| "must never happen" | `invariant` |

The transaction model is the part that needs no work: varp's synchronous
composition already reads shared state from the previous step, which is exactly
DIN/DOUT.

**Totality is the part that does.** Every state variable must be determined in
every branch. A variable left free in some case is not "unchanged" -- it is
anything the solver likes, and BMC will find a violation by choosing it.

## `% 0` is the good answer

When a file has an `invariant`, the default formula is the hunt for a
COUNTEREXAMPLE:

    house(k) = house_init(0) and [A s=1..k] house_next(s)
	       and [E s=0..k] not (St != FAILSAFE)

so `varp sat k=0 home.varp` answers `% 0` and that is the result you want -- it
says the invariant does not break in step 0. There is no model because there is
no violation. The bug file shows the contrast:

    home.varp      k=0 % 0   k=1 % 0   k=2 % 0   k=3 % 0
    home_bug.varp  k=0 % 0   k=1 % 0   k=2 % 1

`sat` is not asking "does this system work" -- it is asking "can it fail", and a
silent no is the whole point.

### Seeing a valid run instead

To look at ordinary behaviour, use the macros the system exports and write your
own goal. Strip the `invariant` line and append, for instance:

    house_init(0) and house_next(1) and house_next(2) and Heater(2)

    St(0)=3,St(1)=3,St(2)=3,Temp(1)=1023,Temp(2)=127,Window(1),WinWas(1),Heater(2), ...

The house stays in `Home` throughout, the temperature falls from 1023 to 127, and
the heater comes on in step 2 -- with the window shut by then, so nothing is
violated. That is also the shape of the consistency check below: a model here
means the transition relation actually has transitions.

## Two traps, both hit while writing this

**Check the system has models at all.** An inconsistent `next` has no
transitions, so everything is unreachable and the proof is vacuous. Strip the
`invariant` line, append

    house_init(0) and house_next(1) and house_next(2)

and run `varp sat bj`. It must answer `% 1`. It answered `% 0` here at first.

**Precedence.** The cause was that `A implies next(X) equ Y` parses as
`(A implies next(X)) equ Y`. Every `equ` in a consequent needs its own
parentheses. Nothing warns; the checker just proves everything.

## Reading the generated model

State numbers are given names, so a gate reads as the program does:

    define INIT 0;
    define NORMAL 1;
    define FAILSAFE 2;
    define Home 3;
    define Night 4;
    define Away 5;

    next  ((St != FAILSAFE) and ((St == Home or St == Night or St == Away) and ...

A state whose name is already taken -- by a signal, a `#param` or a varp keyword
-- keeps its number instead, because defining it twice would shadow the other
one. `#variable Home` next to `#states Home` produces `next(St) == 3` and no
`define Home`.

Each chain is preceded by the source rules it came from, so the model can be read
against the program without holding both files open:

    // ---- Heater__Orange:1 ---------------------------
    //   88: Heater__Orange = 1 ? (IndoorTemp) < ((SetPoint) - (Hysteresis))
    //   89: Heater__Orange = 0 ? (IndoorTemp) > ((SetPoint) + (Hysteresis))

## State numbers, and what they are not

Measured, because the comment in `csp.h` said otherwise and was wrong:

    global  #states on off        ->  on = 3, off = 4
    module  #states on off        ->  on = 3, off = 4   (the SAME numbers)
    module  #states M1 M2         ->  M1 = 5, M2 = 6    (continues globally)

**The number belongs to the NAME, globally.** A module that declares a name the
program already has reuses its number; a module with names of its own continues
the sequence. That is what makes a name legal in several `#states` blocks, and it
is why a duplicate inside one block keeps the first number instead of taking a
second slot. The generator does both, and `#states FAILSAFE A B` gives A = 3
because a reserved name resolves to the built-in and takes no slot.

The `State` VARIABLE, by contrast, is **per object**: `a.State` and `b.State` are
separate storage that happen to share a numbering. Only the numbers are global.

## Why object instances are refused

`#M a` and `#M b` have their own `a.V` and `b.V`. This translator builds one
global picture, sees one `#variable V`, and would model one variable that both
instances share -- a model of a different program. And the consistency check does
NOT catch it, because the transition relation is still perfectly satisfiable.

So `translate/1` returns `{error, {instances_not_modelled, Modules}}` rather than
guessing. It is not a corner case: instance counts across the tree run 0, 1, 2, 3,
5, 10 and 30.

The fix is one varp `system` per `#module` and an `instance` per object, which is
exactly what varp has for it -- see the `producer`/`consumer` example in
`formulas/varp/`. Until then 53 of the 66 examples generate, and the other 13 say
why.

## What is modelled

Only the signals the invariants depend on: `Heater`, `Siren`, `Armed`, `WinWas`,
`ArmWas`, `St`, and the sensors that drive them. Nothing else in `home.csp`
writes those, so a proof about this subsystem is a proof about the house -- the
lights and the coffee maker cannot reach into it. That argument has to be
re-checked whenever a new rule touches one of them.

Timer-driven behaviour is NOT modelled. The hall light and the bathroom fan
depend on `timeout()`, and time in BMC is expensive; they also cannot reach the
invariants. Bringing them in means abstracting a timer to a nondeterministic
`fired` plus an `assume` about ordering.
