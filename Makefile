# OutputsSync Nightly — Makefile
# Orchestre les scripts de scripts/ (détails dans README.md).

APP    := OutputsSync Nightly.app
HAL    := /Library/Audio/Plug-Ins/HAL
BIN    := .build/debug/OutputsSyncNightly

.DEFAULT_GOAL := help
.PHONY: help all app bundle driver selftest run \
        install-driver uninstall-driver reinstall-driver status logs clean

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

all: app driver ## Construit l'app + le driver

app: ## Construit "OutputsSync Nightly.app"
	./scripts/bundle.sh

bundle: app ## Alias de app

driver: ## Compile le driver (build/OutputsSyncDriver.driver)
	./scripts/build-driver.sh

selftest: ## Auto-test de la ligne à retard (sans audio ni GUI)
	swift build
	$(BIN) --selftest

run: app ## Construit puis lance l'app menu-bar
	open "$(APP)"

install-driver: driver ## Installe le driver (sudo + redémarre coreaudiod)
	./scripts/install-driver.sh

uninstall-driver: ## Retire le driver (sudo + redémarre coreaudiod)
	./scripts/uninstall-driver.sh

reinstall-driver: uninstall-driver install-driver ## Retire puis réinstalle le driver

status: ## Indique si le driver/le device virtuel sont présents
	@if [ -d "$(HAL)/OutputsSyncDriver.driver" ]; then \
		echo "Driver installé : oui"; else echo "Driver installé : non"; fi
	@n=$$(system_profiler SPAudioDataType 2>/dev/null | grep -c "OutputsSync Nightly" || true); \
		echo "Device visible  : $$n"

logs: ## Affiche les logs du driver
	log show --last 5m --predicate 'subsystem == "com.outputssync.nightly.driver"'

clean: ## Supprime les artefacts de build (.build, build, .app)
	rm -rf .build build "$(APP)"
