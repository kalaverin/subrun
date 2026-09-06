.PHONY: build install

env:
	@direnv allow . || true
	@mise trust --yes mise.toml
	@mise install

build:
	@mkdir bin/ || true
	@nimble refresh --verbose
	@nim c \
	-d:danger \
		--mm:arc \
		--opt:speed \
		--passC:-flto \
		--passL:-flto \
		--passL:-s \
		-o:bin/subrun \
		src/subrun.nim

install:
	@make build
	@mkdir -p ${HOME}/.local/bin
	@rm "${HOME}/.local/bin/subrun" || true
	@ln -s "${PWD}/bin/subrun" "${HOME}/.local/bin"

.DEFAULT_GOAL := build
