FROM memgraph/memgraph-platform as mg-lab
FROM ghcr.io/apowers313/dev:latest as base

# Nethack Learning Environment dependencies
RUN sudo apt-get install -y build-essential autoconf libtool pkg-config python3-numpy flex bison libbz2-dev
RUN curl https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor > kitware.gpg
RUN sudo mv kitware.gpg /etc/apt/trusted.gpg.d/
RUN sudo chown root:root /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo chmod 644 /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo apt-add-repository 'deb https://apt.kitware.com/ubuntu/ jammy main'
RUN sudo apt-get update
RUN sudo apt-get --allow-unauthenticated install -y cmake kitware-archive-keyring
#RUN pip3 install nle

# Memgraph
WORKDIR /tmp
RUN curl -O https://download.memgraph.com/memgraph/v2.8.0/ubuntu-22.04/memgraph_2.8.0-1_amd64.deb
RUN sudo dpkg -i memgraph_2.8.0-1_amd64.deb
# TODO: install networkx, numpy, scipy
WORKDIR /home/apowers

# Memgraph Lab
# https://github.com/memgraph/memgraph-platform/blob/main/Dockerfile
USER root
COPY --from=mg-lab /lab /lab
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
RUN apt-get install -y nodejs
#RUN rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
USER apowers
EXPOSE 3000

# Update List of Services
COPY index.html /var/run/indexserver/index.html

# Run Server
COPY supervisord.conf /usr/local/etc/supervisord.conf
CMD ["sudo", "-E", "supervisord", "-c", "/usr/local/etc/supervisord.conf"]