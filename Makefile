DOTFILES_EXCLUDES := .DS_Store .git
DOTFILES_TARGET   := $(wildcard .[!.]*)
DOTFILES_DIR      := $(PWD)
DOTFILES_FILES    := $(filter-out $(DOTFILES_EXCLUDES), $(DOTFILES_TARGET))

debug:
	@echo $(HOME)
	@$(foreach val, $(DOTFILES_FILES), echo $(abspath $(val)) $(HOME)/$(val);)

deploy:
	@$(foreach val, $(DOTFILES_FILES), ln -sfnv $(abspath $(val)) $(HOME)/$(val);)

init:
	# @$(foreach val, $(wildcard ./etc/init/*.sh), bash $(val);)
