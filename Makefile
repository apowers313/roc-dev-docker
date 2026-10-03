.PHONY: build fresh test-run stop start restart shell login publish build-noble fresh-noble shell-noble check-noble
DOCKER=sudo docker
SSL_DIR=/home/apowers/atoms-cert
########BUILD_EXTRA=--progress=plain
IMGNAME=apowers313/roc-dev
VERSION=2.0.0
# Side-by-side Ubuntu 24.04 build (Dockerfile.noble)
NOBLE_VERSION=3.0.0-noble
DEV_HOME=/home/apowers/dev
GITPKG=ghcr.io/$(IMGNAME)
SUPERVISOR_PORT=8001:8001
INDEX_PORT=80:80
JUPYTER_PORT=8002:8002
MARIMO_PORT=8003:8003
VSCODE_PORT=8004:8004
MEMGRAPH_PORT=7687:7687
MEMGRAPHLAB_PORT=3000:3000
EXPANDRIVE_PORT=28080:28080
SSHD_PORT=22:22
DOCKER_PORTS=-p $(SUPERVISOR_PORT) -p $(INDEX_PORT) -p $(VSCODE_PORT) -p $(JUPYTER_PORT) -p $(MARIMO_PORT) -p $(MEMGRAPH_PORT) -p $(MEMGRAPHLAB_PORT) -p $(EXPANDRIVE_PORT) -p $(SSHD_PORT)
DOCKER_VOLUMES=-v $(SSL_DIR):/home/apowers/ssl 
RUNCMD=run $(DOCKER_PORTS) $(DOCKER_VOLUMES) $(DOCKER_ENV) -it $(IMGNAME):latest

build:
	$(DOCKER) build . $(BUILD_EXTRA) -t $(IMGNAME):latest -t $(IMGNAME):$(VERSION)

fresh: BUILD_EXTRA += "--no-cache"
fresh: build

########################################
# Ubuntu 24.04 (noble) — side by side
########################################

build-noble:
	$(DOCKER) build . -f Dockerfile.noble $(BUILD_EXTRA) -t $(IMGNAME):$(NOBLE_VERSION)

fresh-noble: BUILD_EXTRA += --no-cache
fresh-noble: build-noble

# Interactive shell on the noble image with the REAL ~/dev mounted.
# No supervisord, no macvlan — safe to run alongside the running dev-env.
shell-noble:
	$(DOCKER) run --rm -it --gpus all $(DOCKER_VOLUMES) -v $(DEV_HOME):/home/apowers $(IMGNAME):$(NOBLE_VERSION) bash

# Same, but runs the smoke test and exits non-zero on failure.
check-noble:
	$(DOCKER) run --rm -it --gpus all $(DOCKER_VOLUMES) -v $(DEV_HOME):/home/apowers $(IMGNAME):$(NOBLE_VERSION) check-env

test-run:
	$(DOCKER) $(RUNCMD)

start: setup-network
	$(DOCKER) compose --env-file .env up --detach dev-env --build

stop:
	$(DOCKER) compose down

.PHONY: setup-network
setup-network:
	sudo ./setup-network.sh

restart: stop start


shell:
	$(DOCKER) $(RUNCMD) bash

logs:
	$(DOCKER) compose logs

# login requires a Personal Access Token (PAT): https://github.com/settings/tokens
login:
	$(DOCKER) login ghcr.io

publish:
	$(DOCKER) tag $(IMGNAME):latest $(GITPKG):latest
	$(DOCKER) tag $(IMGNAME):latest $(GITPKG):$(VERSION)
	$(DOCKER) push $(GITPKG):latest
	$(DOCKER) push $(GITPKG):$(VERSION)
