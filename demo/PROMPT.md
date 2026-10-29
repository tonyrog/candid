# Specifying a house

`home.csp` was written from the prompt below. The point of showing the prompt is
that it has the **same four sections as the language**, which is what makes the
translation mechanical and, more importantly, makes the result reviewable: every
line of the prompt can be read back against a line of the program.

## The prompt

> Build a candyspeak program for my house.
>
> **ROOMS AND THINGS**
> - Hall: motion sensor, ceiling light
> - Kitchen: ceiling light, coffee maker
> - Living room: ceiling light, window sensor
> - Bedroom: reading light, goodnight button by the bed
> - Bathroom: motion sensor, light, extractor fan
> - Outside: light sensor, lamp
> - Whole house: indoor temperature, heating, front door sensor, siren, arm button
>
> **WHAT SHOULD HAPPEN**
> - The hall lights on movement and goes out a few seconds after it stops
> - The bathroom fan runs on for a while after you leave
> - The outdoor lamp comes on when it is dark, with a margin so dusk does not
>   flicker it
> - The heating holds 21 degrees with a deadband so it does not chatter
> - The goodnight button turns off the kitchen and living room and the coffee
>   maker; the bedroom keeps its reading light
> - The arm button toggles the alarm on and off
> - The coffee maker only runs in daylight when somebody is up
>
> **WHAT MUST NEVER HAPPEN**
> - The heating must not run with the living room window open
> - The siren must not sound when the alarm is disarmed
> - The siren must sound if the alarm is armed and the front door opens
>
> **WHAT I WANT TO TUNE WITHOUT A REBUILD**
> - hall hold time, fan run-on, target temperature, deadband, darkness threshold

## Why those four sections

| prompt section | candyspeak |
|---|---|
| rooms and things | `#digital`, `#analog` -- and the panel's widgets fall out of them |
| what should happen | rules |
| what must never happen | invariants |
| what I want to tune | `#param` -- settable live, survives a reflash |

The third section is the one no other home automation system asks for, and it is
the one worth insisting on. "The heating must not run with the window open" is
not the same kind of statement as "the hall lights on movement": the first is a
property that must hold in every reachable state, the second is a behaviour. A
model checker can be pointed at the first. Nothing can be pointed at a pile of
if-statements.

### Prevention, and a net

`home.csp` does both, and the difference matters for what can be proved.

**Prevention** is the rules that force the safe value -- `Heater__Orange = 0 ?
LivingWindow`, last in the block. It works, and it is fragile in two ways:

* Order matters -- a later rule in the same cycle wins, so an invariant written
  early is overwritten by the behaviour it was meant to constrain.
* A rule with **no `#in` block runs only in INIT and NORMAL**. Written outside
  the braces, the window check never ran in `Home` and the heater warmed the
  street. That is what the first draft did, and the panel is how it was caught.

**The net** is the built-in `FAILSAFE` state that the violations transition INTO.
It is not declared: `INIT=0`, `NORMAL=1` and `FAILSAFE=2` are installed by
`csp_rt_init` and user states are numbered from 3 up, so `State = FAILSAFE`
resolves to the built-in one. And it is **STICKY** -- no rule may leave it, only
a reset -- which is exactly right for a safety net: a flaky guard cannot bounce
the house back out of a safe configuration. Verified: with the window shut again
and the house warm, `State` stays 2 until `/reset`.

    State = FAILSAFE ? Heater__Orange && LivingWindow && WinWas
    State = FAILSAFE ? Siren__Red && !Armed && !ArmWas

which turns three scattered guards into ONE property: **FAILSAFE is
unreachable.** That is a sentence varp takes as `invariant State != FAILSAFE`,
and proving it proves the prevention is complete. Patched outputs prove nothing
-- they hide a violation instead of ruling it out.

The stickiness matters for the checker too: because nothing can leave FAILSAFE,
reaching it once is reaching it forever, so `State != FAILSAFE` is a safety
property in the strict sense rather than something that might recover on its own.
A bounded model check that finds no path to it up to depth k has proved something
useful about every longer run as well.

And the landing is soft, because a failsafe that merely stops is not safe in a
dark house:

    #in FAILSAFE
	Heater__Orange = 0
	Siren__Red     = 0
	HallLight      = 1
	OutdoorLamp    = 1
    #end

**`WinWas`/`ArmWas` are not decoration.** Rules read the COMMITTED state, so in
the cycle the window opens, prevention sets `Heater` to 0 while this rule still
sees the 1 committed at the end of the previous cycle. A plain `Heater &&
LivingWindow` therefore fired FAILSAFE every single time the window was opened
in a warm house -- it did, first try. The net only closes on a violation that
PERSISTS: true now, and true last cycle, by which time prevention has had its
turn.

That one-cycle subtlety is a good advertisement for the checker. It is invisible
in review, obvious in the panel, and exactly the kind of thing a bounded model
check finds without being told to look.

## Colours, for now

`Heater__Orange`, `BathFan__Blue`, `Siren__Red`: a `__Colour` suffix names the
lamp colour outright, for the signals where no word in the name implies one. The
panel hides the suffix, so the label reads `Heater`. An unrecognised suffix is
left alone rather than silently eaten.

This is a stopgap for demos and development, **not a design**. It puts
presentation into the identifier, which then has to be spelled out in every rule
that touches the signal. A layout file naming colours per signal is the right
answer, and it needs no change to the language.

## Updating it

Three levels, none of which need a rebuild:

    > KitchenLight = 1        drive a thing directly
    > SetPoint = 220          change a #param -- and /save keeps it over a reflash
    BedLight = 1 ? NightButton    type a NEW rule at the prompt

and `/undo` takes the last one back. That is what makes this a way of working
rather than a compile-and-flash cycle: you specify, watch it in the panel, and
correct the specification where it was wrong -- in the same session, on the
running house.

## Reading the example

`home.csp` is about sixty lines of program and as many of comment, and the
comments are mostly about the two traps above plus one more: a timer is armed
when the motion **stops**, not when it starts, because `T = 1` only arms a
stopped timer and `timeout()` is edge-triggered. Arming it on every cycle of a
held signal does not extend it -- the light goes out while you are still standing
there. Counting down from the moment the room goes quiet is both what works and
what a person means by "stays on for a few seconds after".
