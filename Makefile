.PHONY: build run shell login publish
DOCKER=sudo docker
SSL_DIR=/home/apowers/atoms-cert
#BUILD_EXTRA=--progress=plain
IMGNAME=apowers313/roc-dev
VERSION=1.3.0
GITPKG=ghcr.io/$(IMGNAME)
SUPERVISOR_PORT=8001:8001
INDEX_PORT=80:80
JUPYTER_PORT=8002:8002
VSCODE_PORT=8004:8004
MEMGRAPH_PORT=7687:7687
MEMGRAPHLAB_PORT=3000:3000
DOCKER_PORTS=-p $(SUPERVISOR_PORT) -p $(INDEX_PORT) -p $(VSCODE_PORT) -p $(JUPYTER_PORT) -p $(MEMGRAPH_PORT) -p $(MEMGRAPHLAB_PORT)
DOCKER_VOLUMES=-v $(SSL_DIR):/home/apowers/ssl 
DOCKER_ENV=-e PASSWORD=test
RUNCMD=run $(DOCKER_PORTS) $(DOCKER_VOLUMES) $(DOCKER_ENV) -it $(IMGNAME):latest

build:
	$(DOCKER) build . $(BUILD_EXTRA) -t $(IMGNAME):latest

run:
	$(DOCKER) $(RUNCMD)

shell:
	$(DOCKER) $(RUNCMD) bash

# login requires a Personal Access Token (PAT): https://github.com/settings/tokens
login:
	$(DOCKER) login ghcr.io

publish:
	$(DOCKER) tag $(IMGNAME):latest $(GITPKG):latest
	$(DOCKER) tag $(IMGNAME):latest $(GITPKG):$(VERSION)
	$(DOCKER) push $(GITPKG):latest
	$(DOCKER) push $(GITPKG):$(VERSION)
