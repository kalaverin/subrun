.PHONY: build install

build:
	@mkdir bin/ || true
	@nimble refresh --verbose
	@nimble build --verbose
	@rm bin/subrun || true
	@mv subrun bin/

install:
	@direnv allow . || true
	@mise trust --yes mise.toml
	@mise install
	@make build
	@mkdir -p ${HOME}/.local/bin
	@rm "${HOME}/.local/bin/subrun" || true
	@ln -s "${PWD}/bin/subrun" "${HOME}/.local/bin"

.DEFAULT_GOAL := build
