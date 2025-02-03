FROM memgraph/memgraph-platform AS mg-lab
FROM ubuntu:22.04

######################
# SETUP UBUNTU
######################

# Make REAL Ubuntu
ENV DEBIAN_FRONTEND noninteractive
RUN apt update
RUN apt install -y ubuntu-server

# Install user system
RUN yes | /usr/local/sbin/unminimize

# Basic tools
RUN apt update
RUN apt install -y net-tools sudo man wget python3

# Setup user
RUN useradd -ms /bin/bash apowers
WORKDIR /home/apowers
RUN mkdir /home/apowers/Projects
RUN mkdir /home/apowers/Projects/jupyter
RUN chown apowers:apowers /home/apowers/Projects
RUN echo "apowers ALL=(ALL:All) NOPASSWD:ALL" >> /etc/sudoers
USER apowers
RUN git config --global user.email "apowers@ato.ms"
RUN git config --global user.name "Adam Powers"
RUN sudo chown apowers:apowers -R /home/apowers
RUN unset DEBIAN_FRONTEND

######################
# INSTALL CUDA
######################

# Python
#RUN uv python install 3.10 3.11 3.12 3.13
RUN sudo add-apt-repository -y ppa:deadsnakes/ppa
# Python 3.11
RUN sudo apt install -y python3.11 python3.11-dev
# Python 3.12
RUN sudo apt install -y python3.12 python3.12-dev
# Python 3.13
RUN sudo apt install -y python3.13 python3.12-dev
RUN sudo apt install -y python3-pip

# install Nvidia CUDA
USER root
RUN wget https://developer.download.nvidia.com/compute/cuda/12.0.0/local_installers/cuda_12.0.0_525.60.13_linux.run && sudo sh cuda_12.0.0_525.60.13_linux.run --silent --toolkit && rm cuda_12.0.0_525.60.13_linux.run
USER apowers
ENV CUDA_HOME="/usr/local/cuda"
ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${CUDA_HOME}/lib64:${CUDA_HOME}/extras/CUPTI/lib64"
ENV PATH="${PATH}:${CUDA_HOME}/bin"

######################
# INSTALL MEMGRAPH
######################

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
COPY --from=mg-lab /lab /lab
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
USER apowers
EXPOSE 3000

# Memgraph test data
COPY got.cypherl /tmp/got.cypherl
COPY loaddata.sh /tmp/loaddata.sh

######################
# PROGRAMMING LANGUAGES
######################

# Python installed above

# Rust
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

# node.js
RUN curl -sL https://deb.nodesource.com/setup_22.x | sudo -E bash -
RUN sudo apt-get install -y nodejs

######################
# SERVICES
######################
USER root

# Install OpenSSH server
RUN apt install -y openssh-server
# Configure SSHD.
# SSH login fix. Otherwise user is kicked off after login
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
RUN mkdir /var/run/sshd
RUN bash -c 'install -m755 <(printf "#!/bin/sh\nexit 0") /usr/sbin/policy-rc.d'
RUN ex +'%s/^#\zeListenAddress/\1/g' -scwq /etc/ssh/sshd_config
RUN ex +'%s/^#\zeHostKey .*ssh_host_.*_key/\1/g' -scwq /etc/ssh/sshd_config
RUN RUNLEVEL=1 dpkg-reconfigure openssh-server
RUN ssh-keygen -A -v
RUN update-rc.d ssh defaults
EXPOSE 22

# VS Code
RUN apt install -y jq libatomic1 nano netcat
RUN curl -fsSL https://code-server.dev/install.sh |  sh
EXPOSE 8004

# JupyterLab
RUN pip3 install jupyterlab notebook
COPY ./jupyter_lab_config.py /home/apowers/.jupyter/jupyter_lab_config.py
EXPOSE 8002
# TODO: Jupyter Extensions

# Marimo
RUN pip3 install marimo
EXPOSE 8003

# http index of running services
COPY index.html /var/run/indexserver/index.html
EXPOSE 80

# end of services section
USER apowers

######################
# EXTRA PORTS
######################

# for development purposes
EXPOSE 9000-9099

######################
# EXTRA TOOLS
######################

# Nethack Learning Environment dependencies
RUN sudo apt-get install -y build-essential autoconf libtool pkg-config python3-numpy flex bison libbz2-dev
RUN curl https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor > kitware.gpg
RUN sudo mv kitware.gpg /etc/apt/trusted.gpg.d/
RUN sudo chown root:root /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo chmod 644 /etc/apt/trusted.gpg.d/kitware.gpg
RUN sudo apt-add-repository 'deb https://apt.kitware.com/ubuntu/ jammy main'
RUN sudo apt-get update
RUN sudo apt-get --allow-unauthenticated install -y cmake kitware-archive-keyring

# Extra tools
RUN sudo apt install -y graphviz inetutils-telnet inetutils-ping fortune rsync bsdmainutils

# Rust packages
RUN /home/apowers/.cargo/bin/cargo install typos-cli

# UV
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install poetry
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/home/apowers/.local/bin:${PATH}"
COPY root_bashrc /root/.bashrc

# Hatch
RUN curl -Lo hatch-universal.pkg https://github.com/pypa/hatch/releases/latest/download/hatch-universal.pkg

# pnpm
RUN curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=10.0.0 bash -

# mermaid diagrams
RUN sudo npm install -g mmdc

# C / C++ Utils
RUN sudo apt-get install -y clang clangd

######################
# SUPERVISORD
######################

# Supervisor
RUN sudo pip3 install supervisor
RUN sudo mkdir -p /var/log/supervisord
COPY ./supervisord.base.conf /usr/local/etc/supervisord.base.conf
COPY supervisord.conf /usr/local/etc/supervisord.conf
EXPOSE 8001

# Run Server
USER apowers
CMD ["sudo", "-E", "supervisord", "-c", "/usr/local/etc/supervisord.conf"]
