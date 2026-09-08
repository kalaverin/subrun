.PHONY: build install

env:
	@direnv allow . || true
	@mise trust --yes mise.toml
	@mise install
	@nimble lock
	@nimble setup

build:
	@mkdir bin/ || true
	@nimble refresh --verbose
	@nimble build --verbose
	@rm -f bin/subrun bin/tort
	@mv subrun tort bin/

install:
	@make build
	@mkdir -p ${HOME}/.local/bin
	@rm -f "${HOME}/.local/bin/subrun" "${HOME}/.local/bin/tort"
	@ln -s "${PWD}/bin/subrun" "${PWD}/bin/tort" "${HOME}/.local/bin"

.DEFAULT_GOAL := build
