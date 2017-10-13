CWD=$(shell pwd)
ROOT?=${CWD}
REBAR?=${ROOT}/rebar3.1

all: clean dialyzer xref

run: get_deps shell

shell:
	${REBAR} shell

clean:
	${REBAR} clean

dialyzer:
	${REBAR} dialyzer

xref:
	${REBAR} xref

get_deps:
	${REBAR} get-deps
