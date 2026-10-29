# candid, the candyspeak panel. On the code path it needs csp_tools (the
# parser, candyspeak_varp, csp_list... -- candyspeak's ebin/, built by its
# utils/Makefile), wse (the remote DOM) and this. uart is for a node on a
# serial line, and only then. ellm (and the rester it talks through) is for
# the chat, and only then: without it on the path there is no chat button.
#
# With ERL_LIBS=~/erlang the apps there are found by themselves; the -pa
# below names them anyway, so a plain shell works too. csp_tools lives in
# the candyspeak checkout, whose name is not the app's, so it is always -pa.

CANDYSPEAK ?= $(HOME)/work/candyspeak
WSE    ?= $(HOME)/erlang/wse
UART   ?= $(HOME)/erlang/uart
ELLM   ?= $(HOME)/erlang/ellm
RESTER ?= $(HOME)/erlang/rester

ERLC   = erlc
EBIN   = ebin
PA     = -pa $(EBIN) -pa $(CANDYSPEAK)/ebin -pa $(WSE)/ebin -pa $(UART)/ebin \
	 -pa $(ELLM)/ebin -pa $(RESTER)/ebin
export CANDYSPEAK

all: csp_tools
	@if [ -d "src" -a -f "src/Makefile" ]; then (cd src && $(MAKE) all); fi

# utils/Makefile knows what is stale; asking it every time costs nothing and
# keeps one set of rules for the tree's beams.
csp_tools:
	@$(MAKE) --no-print-directory -s -C $(CANDYSPEAK)/utils

run: all
	erl -s can $(PA) -s candid -config candid.config

# The stub wse must shadow the real one. Each -pa prepends, so the LAST one
# given wins -- test/ebin goes at the end, not the front.
test: all
	mkdir -p test/ebin
	$(ERLC) -o test/ebin test/wse.erl test/panel_test.erl test/fake_llm.erl
	CSP_EXE=$(CANDYSPEAK)/csp \
	  erl -noshell $(PA) -pa test/ebin -s panel_test run

# Generate a varp model from a .csp and check it has transitions at all. The
# consistency probe is not optional: an inconsistent `next' makes every property
# provable, which looks authoritative and means nothing.
VARP_SH ?= $(HOME)/erlang/varp/priv/varp.sh
CSP     ?= demo/home.csp

# Output is <name>_gen.varp, NOT <name>.varp: the hand-written models in demo/
# are commentary and were overwritten once already by a careless default.
varp: all
	erl -noshell $(PA) -eval \
	  'candyspeak_varp:file("$(CSP)", "$(basename $(CSP))_gen.varp"), halt().'
	@echo "wrote $(basename $(CSP))_gen.varp"

varp-check: all
	erl -noshell $(PA) -eval \
	  'candyspeak_varp:check("$(CANDYSPEAK)/examples/*.csp", "$(VARP_SH)"), halt().'

clean:
	rm -f $(EBIN)/*.beam $(EBIN)/*.app test/ebin/*.beam

.PHONY: all csp_tools run test varp varp-check clean
