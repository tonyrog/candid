# Panel widgets

candid, the panel (see its README for how to run it), builds a widget for
every `#digital`, `#analog` and `#field` in a program. The declaration decides
the widget. `#annotate panel` can change how it looks, and it can switch the
widget to another kind, but only to one the declaration allows.

    #analog IndoorTemp:10 in 0
    #annotate panel IndoorTemp kind=dial min=-200 max=400 scale=0.1 unit="°C"

`#annotate` is inert: the compiler skips it and nothing of it reaches a ROM.
candyspeak itself only checks that the target exists. The panel checks the keys
and **warns on stdout** about anything it does not use, whether that is an
unknown key, a key that means nothing on that widget, or a value it does not
understand. Nothing is dropped silently.

## Syntax

    #annotate panel <signal> key=value key=value key ...

| value form       | example                 | arrives as                 |
|------------------|-------------------------|----------------------------|
| bare word        | `kind=dial`             | the word                   |
| integer          | `min=-200`, `max=0x3FF` | integer, hex allowed       |
| float            | `scale=0.000976`        | float                      |
| quoted string    | `unit="°C"`, `color="#f80"` | the text inside        |
| key alone        | `hidden`                | true                       |

Several lines for the same signal are merged; a later key wins.

`*` in place of a signal means **the panel itself**:

    #annotate panel * trace=off          // no logic trace at all
    #annotate panel * glow=off beam=1    // every plot drawn thin and sharp
    #annotate panel * hidden             // hide everything...
    #annotate panel Speed hidden=0       // ...except what you bring back

A key on `*` is a default for every widget it applies to, and a widget's own key
wins over it. Defaults are not checked per widget, so `* min=0` does not warn
on every lamp. `kind`, `label` and `axis` describe one signal, so they are not
inherited from `*`, and the panel warns if you put them there. Anything that
is not a word or a number has to be quoted. That includes `#rrggbb` colours,
units with spaces or symbols, and labels with spaces.

## Which widget a declaration gets

| declaration                       | default widget | `kind=` may also be       |
|-----------------------------------|----------------|---------------------------|
| `#digital ... in`                 | `toggle`       | `push`                    |
| `#digital ... out` / `inout`      | `lamp`         | `action`                  |
| `#analog ... in`                  | `slider`       | `dial`, `value`, `plot`   |
| `#analog ... out`                 | `meter`        | `value`, `plot`           |
| `#analog` on **port 9**           | `pixel`        | (none)                    |
| `#field` in a `#buffer ... in` with no transport | `slider` | as analog in      |
| `#field` in any other buffer      | `meter`        | as analog out             |

The direction is kept on purpose. An input can only become another input
widget, because a panel that draws a dial for a digital pin cannot drive the
pin. If you ask for an impossible kind you get a warning, and the derived
widget is used instead.

A field in a buffer that has a transport (`can`, `tcp`, `udp` ...) is
read-only. The wire fills it, and the panel must not compete with the wire.

Arrays (`#analog P[10]:16 ...`) give one widget per element: `P[0]`..`P[9]`.

Variables, constants and rules do not get widgets yet.

## The widgets

| kind      | shows                                | you can                         | sends                 |
|-----------|--------------------------------------|---------------------------------|-----------------------|
| `toggle`  | a button reading 0/1, lit when 1     | click: flip against csp's value | `X = 0` / `X = 1`     |
| `push`    | same button                          | hold: 1 while held, 0 on release| `X = 1`, `X = 0`      |
| `lamp`    | a round lamp                         | (none)                          | (none)                |
| `action`  | an `off` / `ON` tag that lights up   | (none)                          | (none)                |
| `slider`  | a range slider and a readout         | drag                            | `X = <count>`         |
| `dial`    | a needle (-135°..+135°), slider, readout | drag the slider             | `X = <count>`         |
| `value` (in) | an editable text field            | type a number, Enter            | `X = <what you typed>`|
| `value` (out)| the number                        | (none)                          | (none)                |
| `meter`   | a horizontal bar and a readout       | (none)                          | (none)                |
| `pixel`   | a colour swatch, decoded as RGB565   | hover for the name              | (none)                |
| `plot`    | one channel of an XY picture         | drag on the canvas (inputs only)| `X = <count>` per axis|

`action` is for outputs that *do* something, like a siren, a pump or a valve. A
small dot does not tell you "the pump is running"; a word does.

Pixels share one row of swatches labelled `port 9`, and the channels of a plot
are drawn as one canvas.

### The logic trace

Below the widgets is a logic trace. Each signal gets a row, with its label on
the left in the signal's colour. Each tick adds one column, and the trace
starts over from the left when it reaches the right edge:

* a digital signal is drawn as two levels in its colour,
* a numeric signal is drawn as a height between its `min` and `max`,
* a pixel is drawn as its colour.

`trace=off` on a signal removes its row. `#annotate panel * trace=off` removes
the whole trace. Use that when the panel is just the GUI for a program.

The panel never sets an input widget from csp's value. The control stays where
you left it, and only the readout follows the program. Otherwise the cycle that
writes the value back would fight you while you drag or type.

## Keys

| key      | toggle push | lamp action | slider dial value meter | plot | pixel |
|----------|:-----------:|:-----------:|:-----------------------:|:----:|:-----:|
| `kind`   | ✓           | ✓           | ✓                       | ✓    | ✓     |
| `label`  | ✓           | ✓           | ✓                       | ✓    | ✓     |
| `hidden` | ✓           | ✓           | ✓                       | ✓    | ✓     |
| `trace`  | ✓           | ✓           | ✓                       | ✓    | ✓     |
| `color`  | ✓           | ✓           | ✓                       | ✓    |       |
| `min` `max` |          |             | ✓                       | ✓    |       |
| `scale` `unit` |       |             | ✓                       | ✓    |       |
| `axis` `id` `persist` `shape` `clip` | | |                     | ✓    |       |
| `beam` `dot` `glow` `line` |  |       |                         | ✓    |       |

If you use a key on a widget whose column has no ✓, the panel says so:

    panel: Led: min= unit= means nothing on a lamp, ignored

### `label`

This is the text in the row. It is also the name next to a plot channel and the
hover text on a pixel. By default the label is the signal's name, minus any
`__Colour` suffix. The label is display-only: csp, rules and the dump keep
using the real name.

    #annotate panel Lt3 label="Kitchen"

UTF-8 is decoded, but only up to Latin-1. Characters such as `ö`, `°` and `µ`
work, but `Ω` comes out as its raw bytes, because wse would send it as an array
of numbers otherwise.

### `hidden`

`hidden` on its own, or `hidden=1`, removes the widget completely: it gets no
row and no trace, and it is dropped from any plot it belonged to. If the hidden
channel was a plot's x, the plot sweeps instead. `hidden=0` brings the widget
back without deleting the line. csp is not affected and still has the signal.

### `color`

`color` sets the colour of whatever lights up:

| widget          | what gets the colour                                    |
|-----------------|---------------------------------------------------------|
| toggle, push    | the button's background when it is 1                    |
| lamp            | the lamp when lit, plus a dimmed version when unlit     |
| action          | the tag when ON, plus the dimmed version when off       |
| slider          | the slider (`accent-color`)                             |
| dial            | the needle and the slider                               |
| meter           | the bar                                                 |
| value           | the number                                              |
| plot            | the beam                                                |
| every widget    | its line in the trace                                   |

The value can take three forms:

* a name: `red orange amber yellow green cyan blue purple pink white`
* an HTML colour, quoted: `color="#f80"`, `color="#ff8800"`
* a hex number: `color=0xff8800`

For the named colours, the unlit shade is picked by hand. For hex colours it is
the same hue at about a seventh of the brightness. If the panel does not
recognise the colour, it warns and uses the default.

Defaults when no `color` is given:

* **digital** widgets take the colour from the name. If the name contains
  `green`/`gron`/`grn`, `yellow`/`amber`/`gul`, `blue`/`bla` or
  `white`/`vit`, that colour is used; anything else is red. A `__Colour`
  suffix (`Heater__Orange`) names the colour outright and is removed from the
  label.
* **plots** use phosphor green (`#5f9`). A beam does not guess from the name,
  so `yin` is not yellow.
* **value** widgets use white.
* everything else uses the panel's blue (`#3af`).

Only the American spelling `color` is accepted; `colour=` is warned about as an
unknown key.

### `min`, `max`

These set the range a numeric widget covers, in **counts** (the values csp
holds):

* the travel of a slider or dial,
* where a meter bar is empty and where it is full,
* the needle's sweep,
* the height of the trace line,
* the edges of a plot, and the values you get by dragging on the plot canvas.

The default is the declared swing. An `unsigned` analog or field covers
`0..2^W-1`. A signed one covers `-2^(W-1)..2^(W-1)-1`, so without `min`/`max`
a signed channel at zero sits in the middle and does not hit the floor. A
one-bit field is always 0..1.

Narrow the range when a signal only uses part of it:

    #annotate panel Pot min=300 max=700

Values outside the range are clamped **on screen only**. The needle stops at
the end, and the readout still shows the real number. A slider cannot send
anything outside the range, but csp itself can still hold such a value.

### `scale`, `unit`

These say what a count means in the real world. The readout shows the count and
then the converted value:

    #annotate panel Batt scale=0.000976 unit="V"       // 600 -> "600  0.586 V"
    #annotate panel Rpm  unit="rpm"                    // 600 -> "600 rpm"

* with `scale` and `unit`: `count  value unit`, with three decimals,
* with `scale` only: `count  value`,
* with `unit` only: `count unit` (the count already is the unit),
* with neither: just the count.

Both keys only change what is **displayed**. csp always receives counts. A
slider with `scale=0.1` still sends the count, and a `value` input takes the
count you type, not the converted value.

### Plot keys

Channels with `kind=plot` and the same `id` are drawn as one picture.

| key       | values            | default        | on        |
|-----------|-------------------|----------------|-----------|
| `id`      | any word          | `plot`         | channel   |
| `axis`    | `x`, `y`          | guessed        | channel   |
| `shape`   | `square`, `round` | `square`       | picture   |
| `clip`    | `on`, `off`       | follows shape  | picture   |
| `persist` | 0.0 .. 0.999      | 0.90           | picture   |
| `beam`    | px, 0 = no line   | 1.6            | picture   |
| `dot`     | px, 0 = no dot    | 1.5 × beam     | picture   |
| `glow`    | `on`, `off`       | `on`           | picture   |
| `line`    | `straight`, `step`| `straight`     | picture   |

* `axis`: a plot has one x and any number of y channels. If you do not set it,
  the first channel becomes x and the panel prints that guess. If there is no x
  channel at all, the beam sweeps across the screen like an ordinary scope.
* Picture keys may be set on **any** channel of the group. The first value
  found is used, so you only need to write it once.
* `shape=round` draws a round CRT face with rings and a crosshair. It clips by
  default, so the corners of the value range fall off the glass. `clip=off`
  keeps those corners visible.
* `persist` is how much of the trail is left after 100 ms. The fade is scaled
  by the tick, so changing the tick does not change the trail length.
  `persist=0` gives no trail, only the beam. Every pixel decays toward the
  background, and the distance is rounded down, so a trail always fades out
  completely and leaves no ghost.
* `beam` is the line width and `dot` is the radius of the bright head. `glow`
  makes the head bloom and rounds the line ends. For crisp square curves, use
  `beam=1 dot=0 glow=off line=step`. An odd width is drawn on the half pixel,
  so a 1 px line is exactly one pixel wide.
* `line=step` holds each sample until the next one: the line goes across at the
  old value, then straight up or down to the new one. That is how a square wave
  should look. `straight` draws a diagonal from sample to sample, which makes a
  square wave look like a trapezoid.
* You can drive a plot of **inputs** by holding the mouse on the canvas: x
  follows the pointer, and so does the first y input. One `/step` while paused
  commits both values in the same cycle.
* A plot channel also gets its normal row in the trace, so you can see both
  where the beam is and how it got there.

Example (`demo/xyo.csp`):

    #annotate panel xout  kind=plot axis=x id=plot1 shape=round clip=on scale=0.000976 unit="ms"
    #annotate panel yout1 kind=plot axis=y id=plot1 color=amber scale=0.000976 unit="V"
    #annotate panel yout2 kind=plot axis=y id=plot1 color=red   scale=0.000976 unit="V"

The same plot drawn as sharp logic levels instead of a glowing trace:

    #annotate panel xout kind=plot axis=x id=plot1 beam=1 dot=0 glow=off line=step persist=0.5

## The bar

At the top are the program chooser (every `.csp` file in candid's `demo/`
and in candyspeak's `examples/`), **run** / **pause** / **step**, and the **tick** (10, 25,
50, 100 or 250 ms; the starting value comes from `CANDID_PERIOD`). While
paused, values from widgets are held, and one **step** commits all of them and
runs one cycle that sees them (csp_link sends `/commit` before `/step`).

Between them is the **target**: what the panel is connected to. It is read
when you press Enter, and the widgets and the code view stay as they are.

| Target | Means |
|---|---|
| empty, `local` | a csp of the panel's own, running the chosen file, on `vcan0` |
| `can0` | the same, on that CAN interface |
| `host:port` | a node's console on tcp |
| `/dev/ttyUSB0[@baud]` | a node's console on a serial line, 115200 if unsaid; a pattern such as `/dev/serial/by-id/usb-*` works if it matches one device |
| `can0 to=0x601 from=0x581` | a node's console on CAN: the panel sends on `to`, the node answers on `from`. The interface is one the can application has (`candid.config`) |

Flags follow, separated by spaces:

* `rom`, `patch`, `eeprom`: the program without a patch, with the one running
  (`/dump patch`), or with the one stored (`/dump eeprom`). A node is read
  with `patch` unless told otherwise. A csp of the panel's own compiles its
  file either way, and with `eeprom` it also loads the store.
* `image=A`: read a node's program from that flash slot, not from the image it
  runs.
* `frame=N` (CAN): bytes in each frame the panel sends, 1 to 8, default 4.
  `gap=MS` (CAN): the pause between them, default 20. There is no ack and no
  resend. A node relays one frame a cycle, has no receive queue, and a relay
  written as rules (`examples/relay`) moves 4 bytes per assignment.

The node end of CAN is the relay in `examples/relay/node.csp` with `can`
buffers in place of `udp`: `#buffer Rx:4 in can 0x601` and
`#buffer Tx:4 out can 0x581`. It moves 4 bytes per cycle. On the host, at
about ten cycles a second, that is 40 bytes a second: a `/dump rom` of 760
bytes takes 20 s, a state 2 s. The console ring (`CSP_CONSOLE_BYTES`, 4096 on
the host) has to hold a whole reply, or what does not fit is lost.

A board's own console port needs nothing on the node: its USB serial is the
console. A csp on the host stands in for a serial node with
`csp --uart=pty examples/uart_serv.csp`: it prints `uart 0: /dev/pts/N`, and
that goes in the target field. `make test` in candid does exactly that.

A node has no dump stream. The panel reads its program once (`/dump rom`, then
the patch), and on every tick it asks `/dump state` and names the values from
that program. The program comes back as source too (`csp_list`), and the panel
rebuilds itself from it -- code view and widgets are what the node RUNS, not
the file that was open. It is kept as `$TMPDIR/csp_node/<target>.csp`, which is
what the file chooser then shows. To run a file again, type `local` in the
target field and pick it. Run, pause, step and the widgets send the same commands as they
do to a csp of the panel's own. Connecting does not pause a node, even when
`candid.config` says `{mode, pause}`. Closing lets go of a node; it is never
sent `/quit`. A node does not say which rules fired, so the code view's
`fired` colour stays dark. The status box beside the clock says what is
connected, or why not.

After those come what is shown:

* **trace:** hide or show.
* **code:** hide, ladder or code.
* **theme:** dark or light.

Both views start hidden, the trace and the code view, and the program starts
running, unless `candid.config` says otherwise:

```erlang
{candid,
 [{mode, pause},            %% run | pause
  {trace, show},            %% hide | show
  {code, ladder},           %% hide | ladder | code
  {theme, light},           %% dark | light
  {colors, [{true, "#3f3"}, {fired, "#fb3"}]}]}
```

`colors` sets the code view's highlights, as any css colour: `true` (a contact
that holds), `fired` (a coil whose rule fired), `next` (the outline of a coil
whose guard holds), `block` (the `#in`/`#when` header in force), `want` and
`unwant` (marks, see below). `make run` passes `-config candid.config`.

The choices made on the bar are kept when you pick another program.
Light mode is the dark panel inverted and turned back to its own hues, on a
pale blue page. One filter on the root reaches every inline colour, the
canvases included.

## The layout

Everything is in one window:

* **The top frame**, under the bar, says where the program is. It shows
  `State` by name, the cycle, and the program's own clock (`time`, from csp,
  which stands still while paused). Next come the goal with **clear**,
  **solve** and the bound (see the model, below), then varp's answer, and the
  table of the program's values that have no widget of their own.
* **The devices**, on the left, scroll on their own.
* **The code view**, on the right, scrolls on its own. A long rung scrolls
  sideways inside it.
* **The trace**, at the bottom, when shown.

## The code view

To the right of the devices are the program's rules, in two renderings that
you pick with **ladder** or **code** in the bar:

* **ladder** draws each guard Sternol style. An AND runs horizontally, as
  contacts in series. An OR stacks its branches vertically between two rails.
  The assignments form the coil at the end of the rung. An unguarded
  `X = <condition>` is drawn as a classic ladder line, with the condition as
  contacts and `X` alone as the coil.
* **code** is candyspeak, printed back from the parse tree. Comments and the
  original layout are therefore gone.

What the colours mean:

* **Green contact:** the condition holds in the current state. Setting an
  input lights what it enables at once, before the step that acts on it.
* **Dashed contact:** the panel cannot know the value from the dump. This
  covers `elapsed()`, `timeout()`, buffer bytes and calls.
* **Filled coil:** csp reports that the rule fired in the last cycle. For an
  `X = <condition>` rung, it means that `X` is on.
* **Outlined coil:** the rule fires on the next step.
* **Faded row:** the row sits in a block that is not active. A rule outside
  every block counts as `#in INIT NORMAL`, as in csp.

### Marks and the model

Click a contact once and it should hold (a solid frame), twice and it should
not (a dashed frame), three times to forget it. The marks add up to one
condition, the **goal**, shown in the top frame as candyspeak, with an object's
names made whole (`m0.X`):

    goal: !(N > 2) && m0.X && !Go

A **signal** is marked the same way, by clicking its label among the devices
or its cell in a value table. One bit is marked as on (`Siren`) or off
(`!Siren`). A wider value is marked as equal or not equal to its value at the
moment of the click (`N == 5`, `!(N == 5)`). So "is Siren ever set" is a click
on Siren and **solve**.

Marks are kept across tabs. To flip an input, use its widget.

**solve** asks varp whether some run of the program, from `INIT`, reaches the
goal within the bound (`k ≤ 10` by default; 1, 2, 5, 10, 20 or 50 steps). The
program is translated by `candyspeak_varp` with the goal as its `reach`, and
`varp bmc` searches (bounded model checking: try 0 steps, then 1, and so on up
to the bound). When no run gets there, varp tries to prove that none ever
does, by k-induction (`varp bmc --induction`): it shows that no run of k+1
steps can end in the goal unless it already was there before. The answer is
one of

- "never: ... no step can lead into it" -- 0-induction, the rules alone rule
  the goal out, whatever state came before. `Yellow && Green` in a program
  where green means all three buttons and yellow exactly one is this kind:
  the same contradiction `varp sat` finds in the plain formula.
- "never: ... no run reaches it (proved by N-induction)" -- states where the
  goal holds exist, but it takes N steps of history to see no run gets there.
- "not reachable within k steps, and not proved for ever" -- neither; a
  longer bound may find a run, or a proof.
- the trace: a column per step, `State` by name.

A model with no transitions at all has no trace and proves anything, so the
model is first asked for a run of two steps; without one the answer says so
instead.

In the trace a `-` means any value does. A row
`L26?` is a guard the model cannot read (a call, a part), left as a free
choice of whether the rule on line 26 may fire. A trace that uses such a
choice may not be a run the real program can make.

Timers are modelled. Each step has a row `ms`, the time that passes before it,
and each timer `T` two: whether it runs (`T`) and how long it has (`T ms`).
`timeout(T)`, `T.fired`, `T` and `elapsed(T)` are read from them, `T = 1`
starts it over and `T = 0` stops it, as in the runtime. A timer declared `= 1`
runs from the setup, before `INIT`. A timer whose period is not a number (a
`#param` counts, at its declared value) is not modelled.

**▲ ▼** walk the trace one cycle at a time, without touching csp. A line
says what the cycle is: `step 4 -> 5: +15 ms ErrUsb=1 CanFrame frame =>
EnDb.Hold=30, ...`, the time and inputs that come in and what changes. The
code view, the top frame's values and `State` show that cycle as the model
has it: the state of step 4 with the inputs of step 5, the timers' timeouts
from the model, and a coil lit where its rule fires. The devices on the left
stay csp's. A found trace opens on its first cycle; **live** goes back to
csp's own values, and so does **replay**. **table** shows the whole trace.

**replay** plays a found trace on the running csp. It resets csp to its
initial values, pauses it and holds its clock (`/clock`). Each **step** then
sets the trace's inputs for that step, moves the clock by the step's `ms` and
runs one cycle. The step's column is lit, and a state value csp disagrees with
turns red and stays red -- which is what a trace through a guard the model
could not read looks like when the program does not take it.

A frame the trace receives is sent on `vcan0`, the bus csp listens to, with
the buffer's CAN id (its declaration's, or an unconditional `B.id = X`). It
goes out a step ahead: csp takes a frame in during one cycle and the rules see
`.rx` in the next -- which is also why no rule sees a frame in `INIT`, and the
model says so. A buffer with no fixed id cannot be sent to, and a trace that
receives on one says so. `make run` starts the `can` application the frames go
through. `#param`s are taken at their declared values, in the check and in
solve alike.

**clear** drops the marks and checks the model itself, before you believe an
answer from it:

* It checks that the model **runs** at all. A model with no transitions makes
  every goal unreachable, which would mean nothing.
* It lists what the model **leaves free**: the inputs, any value each step;
  variables written by rules it cannot model; `#param`s, any value but frozen;
  the guards that are a free choice; and how many rules are not modelled.

Objects are modelled as the runtime makes them: every member once per
instance, named as csp names it (`EnDb.Hold`), each instance with its own
`State`. A binding on the instance line is what it is in the runtime: the
formula of a `#local ... in`, a rule in every state for `X <- E`, a write in
the instance's `INIT` for `X = E`, the period for `T.period = P`. Objects
inside a module work too (`aaaa.a0.S`). A module that is not in the program
(passed as a separate file) is reported by name. varp is
found as `~/erlang/varp/priv/varp.sh`, or set `VARP_SH`. A run is limited to 30
seconds.

How it works:

* **Fired rules come from csp.** csp started with `--fired` prints
  `{fired,Cycle,[{Object,File,Line},...]}.` after the state dump, whenever the
  set of rules that fired changes, and `{clock,Cycle,Ms}.` every cycle (the
  top frame's cycle and time). `Object` is `""` for the program itself and
  the instance name for a module's rule, which is one piece of code run once
  per object. The rule is named by where it is written, because instance lines
  add binding rules of their own that no source line spells out. A coil stays
  lit for 600 ms after it last fired, so a one-cycle `timeout` rule can be
  seen.
* **Contacts are worked out in the panel** by `candyspeak_eval`, over the
  dumped values. A `#local` is evaluated from its formula. A `#param` is taken
  at its declared value, so a param patched at run time is not seen.

The values that have no widget of their own, the variables and the `#local`s
(in italics, worked out by the panel), are a table in the top frame. An
object's tab has its own table.

A program with `#module` gets **tabs**: `main`, then one tab per object. An
object's tab shows its bindings (`#Add a1 Cin=a0.Cout ...`), its values, and
its module's rules, evaluated over that object's values (`a1.A` is read as
`A`). The coils light per object, from the `Object` that `--fired`
reports.

A declaration inside a `#module` becomes one widget per object, named as csp
dumps it. The Pixel module in `cpx_m.csp` gives ten pixels, `p0.P` to `p9.P`.
Before this change it gave a single pixel `P` that nothing ever wrote.

## The chat

With ellm (and the rester it talks through) on the code path, the bar has a
`chat` button. It opens a pane on the right where a language model helps write,
read and debug the program -- with the same things at hand as you: the
program shown (the node's own, listed off its image, when the panel runs a
node), the values right now, the manual, the tree's `.csp` files, the
compiler, varp, and the run, pause and step buttons.

What it may do. It reads freely. It writes only new files of its own, in
`demo/` unless `{chat, [{dir, Dir}]}` says otherwise, and only a file it made
in this session may be written again -- `dl1200.csp` and friends are safe.
`load` checks a program with csp first and then runs it in the panel, so it
needs a local target. Against a NODE it drives nothing (no set, pause, step)
unless `{chat, [{node_control, true}]}` is in `candid.config`: a node may be
wired to something that moves.

It works on source text with line numbers and gets the compiler's errors back
as `program:LINE`; a change to a long program is an `edit` (old text, new
text) rather than the whole file. `prove` answers as solve does: a trace,
"never" or "always hold" with the k-induction that proved it, or "not within
k steps" when neither was found -- and names what the model left free, where
a counterexample may be one the program cannot take.

Configuration is ellm's own `{ellm, [...]}` in `candid.config` (backend, model,
key -- the key as `"$ANTHROPIC_API_KEY"` or `".authinfo"`, not in the file),
and `{candid, [{chat, off}]}` takes the button away.

## Notes and known gaps

* **The look is one map per widget.** Every key in the tables above is read
  the same way for every kind (`candid:look/3`). Before this change, `label`
  and `hidden` passed the key check and then did nothing, and `color`, `unit`,
  `scale`, `min` and `max` only had an effect on plots.
  `color=amber` in `xyt.csp` silently fell back to phosphor, because the
  palette did not contain amber. `min=-512` was a syntax error, because the
  annotation grammar had no negative numbers. All of these are fixed now and
  covered by tests (`make test` in candid).
* **`__Colour` in names** is now redundant with `color=`. It puts presentation
  into the identifier, which then has to be spelled out in every rule. It still
  works, but `color=` is the better way.
* **Display only.** `scale` cannot be used to enter values in real-world units.
  Doing that would need the panel to convert back to counts and round, and then
  the panel would send something you cannot see typed at the prompt.
* **A plot has no label of its own.** The text next to the canvas is the `id`.
* **Fixed geometry.** A plot is always 240 px square, a slider is 200 px, and
  the trace is 720 px plus 110 px for labels. There are no size keys. A label
  longer than 13 characters is cut short in the trace.
* **Beam settings are per plot, not per channel.** All channels in one picture
  share `beam`, `dot`, `glow` and `line`.
* **Port 9 is the CPX pixel strip.** This is an assumption about the board, not
  something the language says.
* **`hidden` is per tool.** `#annotate varp X hidden` belongs to the model
  checker and does not hide anything in the panel.
