.PHONY: build fresh test-run stop start restart shell login publish check build-jammy fresh-jammy rollback verify nogpu
DOCKER=sudo docker
SSL_DIR=/home/apowers/atoms-cert
########BUILD_EXTRA=--progress=plain
IMGNAME=apowers313/roc-dev
# Ubuntu 24.04 (noble) is the default: ./Dockerfile
VERSION=3.0.0
# Previous Ubuntu 22.04 build, kept for rollback: ./Dockerfile.jammy
JAMMY_VERSION=2.0.0
DEV_HOME=/home/apowers/dev
COMPOSE_JAMMY=-f compose.yml -f compose.jammy.yml
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
RUNCMD=run $(DOCKER_PORTS) $(DOCKER_VOLUMES) $(DOCKER_ENV) -it $(IMGNAME):$(VERSION)

build:
	$(DOCKER) build . $(BUILD_EXTRA) -t $(IMGNAME):latest -t $(IMGNAME):$(VERSION)

fresh: BUILD_EXTRA += "--no-cache"
fresh: build

# Smoke test the current image against the real ~/dev. Runs no services and
# no macvlan, so it is safe alongside a running dev-env.
# --privileged is required: /etc/nvidia-container-runtime/config.toml sets
# no-cgroups = true, so without it the GPU check fails on a healthy driver.
check:
	$(DOCKER) run --rm -it --gpus all --privileged $(DOCKER_VOLUMES) \
		-v $(DEV_HOME):/home/apowers $(IMGNAME):$(VERSION) check-env

########################################
# Ubuntu 22.04 rollback (Dockerfile.jammy)
########################################

build-jammy:
	$(DOCKER) build . -f Dockerfile.jammy $(BUILD_EXTRA) -t $(IMGNAME):$(JAMMY_VERSION)

fresh-jammy: BUILD_EXTRA += --no-cache
fresh-jammy: build-jammy

# Swap the running dev-env back to the 22.04 image.
rollback: setup-network
	$(DOCKER) compose $(COMPOSE_JAMMY) --env-file .env up -d --no-build dev-env

########################################
# Diagnostics
########################################

# supervisord process states, in-container smoke test, and a port sweep
# against $DEV_IP. Read-only.
verify:
	./migrate-to-noble.sh verify

# Start dev-env with the GPU reservation stripped out, for when the host
# nvidia driver is mismatched and no GPU container can start.
nogpu:
	./migrate-to-noble.sh nogpu

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
