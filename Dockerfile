FROM memgraph/memgraph-platform AS mg-lab
FROM ghcr.io/apowers313/dev:1.4.4 AS base

# Nethack Learning Environment dependencies
RUN sudo apt-get install -y build-essential autoconf libtool pkg-config python3-numpy flex bison libbz2-dev
RUN curl https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor > kitware.gpg
RUN sudo mv kitware.gpg /etc/apt/trusted.gpg.d/
RUN sudo chown root:root /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo chmod 644 /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo apt-add-repository 'deb https://apt.kitware.com/ubuntu/ jammy main'
RUN sudo apt-get update
RUN sudo apt-get --allow-unauthenticated install -y cmake kitware-archive-keyring

# Memgraph
WORKDIR /tmp
RUN curl -O https://download.memgraph.com/memgraph/v2.8.0/ubuntu-22.04/memgraph_2.8.0-1_amd64.deb
RUN sudo dpkg -i memgraph_2.8.0-1_amd64.deb
WORKDIR /home/apowers
RUN pip install -U networkx numpy scipy
RUN sudo apt install -y libssl-dev
EXPOSE 7687

# Memgraph Lab (Docker clone)
# https://github.com/memgraph/memgraph-platform/blob/main/Dockerfile
USER root
COPY --from=mg-lab /lab /lab
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
USER apowers
EXPOSE 3000

# Memgraph test data
COPY got.cypherl /tmp/got.cypherl
COPY loaddata.sh /tmp/loaddata.sh

# Install poetry
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/home/apowers/.local/bin:${PATH}"
COPY root_bashrc /root/.bashrc

# install graphviz
RUN sudo apt install -y graphviz

# install Nvidia CUDA
RUN sudo apt install -y wget
USER root
RUN wget https://developer.download.nvidia.com/compute/cuda/12.0.0/local_installers/cuda_12.0.0_525.60.13_linux.run && sudo sh cuda_12.0.0_525.60.13_linux.run --silent --toolkit && rm cuda_12.0.0_525.60.13_linux.run
USER apowers
ENV CUDA_HOME="/usr/local/cuda"
ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${CUDA_HOME}/lib64:${CUDA_HOME}/extras/CUPTI/lib64"
ENV PATH="${PATH}:${CUDA_HOME}/bin"

# Update List of Services
COPY index.html /var/run/indexserver/index.html

# Run Server
COPY supervisord.conf /usr/local/etc/supervisord.conf
CMD ["sudo", "-E", "supervisord", "-c", "/usr/local/etc/supervisord.conf"]
